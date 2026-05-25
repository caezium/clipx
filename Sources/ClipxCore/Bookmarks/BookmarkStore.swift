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

    init(database: Database) {
        self.database = database
    }

    /// Adds a new library folder by creating a security-scoped bookmark.
    /// Idempotent: if the folder is already known, refreshes its bookmark
    /// and `online = true` instead of throwing a UNIQUE-constraint error.
    func addFolder(url: URL) throws {
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
    }

    /// Resolves all stored bookmarks into URLs with security access started.
    /// Caller is responsible for matching `stopAccessing()` (or call `stopAll()`).
    ///
    /// When `bookmarkDataIsStale` returns true, we re-mint the bookmark and
    /// persist it. Without this the bookmark eventually hard-fails and the
    /// user has to re-pick every folder.
    func resumeAccess() -> [URL] {
        var urls: [URL] = []
        do {
            let folders: [FolderRecord] = try database.read { db in
                try FolderRecord.fetchAll(db)
            }
            for folder in folders {
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { continue }

                if stale {
                    refreshBookmark(at: url)
                }

                if url.startAccessingSecurityScopedResource() {
                    lock.lock()
                    startedAccess[url.path] = url
                    lock.unlock()
                    urls.append(url)
                }
            }
        } catch {
            ClipxLog.bookmarks.error("resumeAccess failed: \(String(describing: error), privacy: .public)")
        }
        return urls
    }

    /// Best-effort re-creation of a stale bookmark; failures are logged but
    /// not surfaced because we still try to use the resolved URL this session.
    private func refreshBookmark(at url: URL) {
        do {
            let fresh = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try database.write { db in
                try db.execute(
                    sql: "UPDATE folders SET bookmark = ? WHERE path = ?",
                    arguments: [fresh, url.path]
                )
            }
            ClipxLog.bookmarks.info("refreshed stale bookmark for \(url.path, privacy: .public)")
        } catch {
            ClipxLog.bookmarks.error("refreshBookmark failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stopAll() {
        lock.lock()
        let urls = startedAccess.values
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
                let escaped = sqlLikeEscape(folder.path)
                let fileCount = (try? database.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM sources WHERE path LIKE ? ESCAPE '\\'",
                        arguments: ["\(escaped)/%"]
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

    func removeFolder(path: String) {
        // Stop the matching security scope BEFORE deleting the row, otherwise
        // we leak a sandbox reference per remove.
        lock.lock()
        let started = startedAccess.removeValue(forKey: path)
        lock.unlock()
        started?.stopAccessingSecurityScopedResource()

        try? database.write { db in
            try FolderRecord.filter(FolderRecord.Columns.path == path).deleteAll(db)
        }
    }
}
