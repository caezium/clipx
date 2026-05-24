import Foundation
import AppKit
import GRDB

/// Persists security-scoped bookmarks for user-chosen library folders so the
/// app can re-access them after relaunch (required for sandboxed MAS build,
/// and good practice for Direct as well).
final class BookmarkStore {
    private let database: Database
    private var startedAccess: [URL] = []

    init(database: Database) {
        self.database = database
    }

    /// Adds a new library folder by creating a security-scoped bookmark.
    /// Idempotent: if the folder is already known, refreshes its bookmark
    /// and `online = true` instead of throwing a UNIQUE-constraint error.
    func addFolder(url: URL) throws {
        #if MAS_BUILD
        let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
        #endif
        let bookmark = try url.bookmarkData(
            options: opts,
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
    func resumeAccess() -> [URL] {
        var urls: [URL] = []
        do {
            let folders: [FolderRecord] = try database.read { db in
                try FolderRecord.fetchAll(db)
            }
            for folder in folders {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    if url.startAccessingSecurityScopedResource() {
                        startedAccess.append(url)
                        urls.append(url)
                    }
                }
            }
        } catch {
            NSLog("BookmarkStore.resumeAccess failed: \(error)")
        }
        return urls
    }

    func stopAll() {
        for url in startedAccess {
            url.stopAccessingSecurityScopedResource()
        }
        startedAccess.removeAll()
    }

    func allFolders() -> [LibraryFolderDescriptor] {
        do {
            let folders: [FolderRecord] = try database.read { db in
                try FolderRecord.fetchAll(db)
            }
            return folders.map { folder in
                let fileCount = (try? database.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM sources WHERE path LIKE ?",
                        arguments: ["\(folder.path)/%"]
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
        try? database.write { db in
            try FolderRecord.filter(FolderRecord.Columns.path == path).deleteAll(db)
        }
    }
}
