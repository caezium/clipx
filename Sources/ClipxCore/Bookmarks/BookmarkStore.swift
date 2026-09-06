import Foundation
import AppKit
import GRDB

/// Persists security-scoped bookmarks for user-chosen library folders so the
/// app can re-access them after relaunch (required for sandboxed MAS build,
/// and good practice for Direct as well).
final class BookmarkStore {
    private let database: Database
    /// Started URLs keyed by canonical path so `removeFolder` can stop the
    /// matching scope and we don't leak a sandbox reference per remove.
    private var startedAccess: [String: URL] = [:]
    private let lock = NSLock()
    private(set) var accessFailures: [String] = []

    init(database: Database) {
        self.database = database
    }

    /// Adds a new library folder by creating a security-scoped bookmark.
    /// Idempotent: if the folder is already known, refreshes its bookmark
    /// and `online = true` instead of throwing a UNIQUE-constraint error.
    func addFolder(url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        var saved = false
        defer { if started && !saved { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try database.write { db in
            if var existing = try FolderRecord
                .filter(FolderRecord.Columns.path == url.path)
                .fetchOne(db) {
                existing.bookmark = bookmark
                existing.online = true
                try existing.update(db)
            } else {
                var record = FolderRecord(
                    id: nil,
                    path: url.path,
                    bookmark: bookmark,
                    addedAt: Int64(Date().timeIntervalSince1970),
                    lastScanAt: nil,
                    online: true
                )
                try record.insert(db)
            }
        }
        if started { retainAccess(url, replacing: url.path) }
        saved = true
    }

    /// Resolves all stored bookmarks into URLs with security access started.
    /// Caller is responsible for matching `stopAccessing()` (or call `stopAll()`).
    ///
    /// When `bookmarkDataIsStale` returns true, we re-mint the bookmark and
    /// persist it. Without this the bookmark eventually hard-fails and the
    /// user has to re-pick every folder.
    func resumeAccess() -> [URL] {
        var urls: [URL] = []
        accessFailures = []
        do {
            let folders: [FolderRecord] = try database.read { db in
                try FolderRecord.fetchAll(db)
            }
            for folder in folders {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: folder.bookmark,
                        options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                    let started = url.startAccessingSecurityScopedResource()
                    var retained = false
                    defer { if started && !retained { url.stopAccessingSecurityScopedResource() } }
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    let bookmark = stale || folder.path != url.path
                        ? try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        : folder.bookmark
                    if let id = folder.id { try relinkFolder(id: id, to: url, bookmark: bookmark) }
                    if started { retainAccess(url, replacing: folder.path); retained = true }
                    urls.append(url)
                } catch {
                    accessFailures.append(folder.path)
                    markUnavailable(folder.path)
                    ClipxLog.bookmarks.error("Cannot access folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            ClipxLog.bookmarks.error("resumeAccess failed: \(String(describing: error), privacy: .public)")
        }
        return urls
    }

    /// Folder identity is the row ID, not the last resolved path. Move source
    /// paths in the same transaction so clips retain every association.
    func relinkFolder(id: Int64, to url: URL, bookmark: Data) throws {
        try database.write { db in
            guard let folder = try FolderRecord.fetchOne(db, key: id) else { return }
            if folder.path != url.path {
                let prefix = folderDescendantPrefix(folder.path)
                try db.execute(sql: """
                    UPDATE sources SET path = ? || substr(path, length(?) + 1)
                    WHERE substr(path, 1, length(?)) = ? COLLATE BINARY
                    """, arguments: [folderDescendantPrefix(url.path), prefix, prefix, prefix])
            }
            try db.execute(sql: "UPDATE folders SET path = ?, bookmark = ?, online = 1 WHERE id = ?",
                           arguments: [url.path, bookmark, id])
        }
    }

    private func retainAccess(_ url: URL, replacing oldPath: String) {
        lock.lock()
        let old = startedAccess.removeValue(forKey: oldPath)
        let duplicate = startedAccess.updateValue(url, forKey: url.path)
        lock.unlock()
        old?.stopAccessingSecurityScopedResource()
        duplicate?.stopAccessingSecurityScopedResource()
    }

    private func markUnavailable(_ path: String) {
        try? database.write { db in
            try db.execute(sql: "UPDATE folders SET online = 0 WHERE path = ?", arguments: [path])
            let prefix = folderDescendantPrefix(path)
            try db.execute(sql: "UPDATE sources SET online = 0 WHERE substr(path, 1, length(?)) = ? COLLATE BINARY",
                           arguments: [prefix, prefix])
        }
    }

    func stopAll() {
        lock.lock()
        let urls = Array(startedAccess.values)
        startedAccess.removeAll()
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func allFolders() -> [LibraryFolderDescriptor] {
        do {
            let folders: [FolderRecord] = try database.read { db in
                try FolderRecord.fetchAll(db)
            }
            return folders.map { folder in
                let prefix = folderDescendantPrefix(folder.path)
                let fileCount = (try? database.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM sources WHERE substr(path, 1, length(?)) = ? COLLATE BINARY",
                        arguments: [prefix, prefix]
                    ) ?? 0
                }) ?? 0
                return LibraryFolderDescriptor(
                    path: folder.path,
                    online: folder.online,
                    fileCount: fileCount
                )
            }
        } catch {
            return []
        }
    }

    @discardableResult
    func removeFolder(path: String) -> Bool {
        do {
            _ = try database.write { db in
                try FolderRecord.filter(FolderRecord.Columns.path == path).deleteAll(db)
            }
        } catch {
            ClipxLog.bookmarks.error("removeFolder failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Stop the matching security scope BEFORE deleting the row, otherwise
        // we leak a sandbox reference per remove.
        lock.lock()
        let started = startedAccess.removeValue(forKey: path)
        lock.unlock()
        started?.stopAccessingSecurityScopedResource()

        return true
    }
}
