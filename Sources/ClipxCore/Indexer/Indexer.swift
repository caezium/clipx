import Foundation
import GRDB

/// Walks a folder, extracts metadata for each video file, and writes Source
/// records. Idempotent: re-indexing the same file updates rather than dupes.
///
/// Modeled as an `actor` (not `@MainActor`) so DB writes run off the main
/// thread — previously every file's `database.write` blocked the UI. Library
/// refresh notifications are debounced through a single trailing-edge bump
/// instead of one per file (5k files used to fire 5k SwiftUI re-renders).
actor Indexer {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "mts", "m2ts",
        "webm", "wmv", "flv", "hevc", "prores"
    ]

    private let database: Database
    private let thumbnailEngine: ThumbnailEngine
    private var pendingRevisionBump: Task<Void, Never>?

    init(database: Database, thumbnailEngine: ThumbnailEngine) {
        self.database = database
        self.thumbnailEngine = thumbnailEngine
    }

    /// Scans the given root folder recursively for videos and indexes them.
    /// Calls `progress` periodically with (processed, total).
    func index(folder: URL, progress: ((Int, Int) -> Void)? = nil) async {
        let urls = collectVideoFiles(at: folder)
        let total = urls.count
        var processed = 0
        for url in urls {
            await indexFile(url)
            processed += 1
            progress?(processed, total)
        }
    }

    func indexFile(_ url: URL) async {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
            let size = (attrs[.size] as? Int64) ?? 0

            // Skip unchanged. Two paths:
            //  * post-v2 rows with a stored size: require BOTH mtime AND size
            //    to match (catches `cp -p` where mtime is preserved but
            //    bytes differ).
            //  * pre-v2 rows where size is nil: trust mtime alone. Without
            //    this, every existing row gets re-indexed on first launch
            //    after the v2 migration, which queues ~100 thumbnail
            //    completions on the main thread and looks like a freeze.
            //    Size gets populated the next time the file legitimately
            //    changes.
            let existing: Source? = try database.read { db in
                try Source.filter(Source.Columns.path == url.path).fetchOne(db)
            }
            if let existing, existing.mtime == mtime {
                if existing.size == nil || existing.size == size {
                    // Backfill size for pre-v2 rows so we converge.
                    if existing.size == nil, let existingID = existing.id {
                        try? database.write { db in
                            try db.execute(
                                sql: "UPDATE sources SET size = ? WHERE id = ?",
                                arguments: [size, existingID]
                            )
                        }
                    }
                    return
                }
            }

            let hash = try FileHasher.quickHash(url: url)
            let meta = await MetadataExtractor.extract(url: url)
            let importedAt = existing?.importedAt ?? Int64(Date().timeIntervalSince1970)

            // Atomic upsert. Without ON CONFLICT, a concurrent FSEvents fire
            // for the same path could trip `path UNIQUE` and the swallowed
            // catch above would silently drop a real file.
            let insertedID: Int64 = try database.write { db in
                try db.execute(sql: """
                    INSERT INTO sources
                        (path, bookmark, hash, mtime, size,
                         duration_ms, width, height, fps, codec,
                         audio_channels, color_space, created_at, imported_at,
                         thumb_path, online, notes)
                    VALUES (?, NULL, ?, ?, ?,
                            ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            NULL, 1, NULL)
                    ON CONFLICT(path) DO UPDATE SET
                        hash = excluded.hash,
                        mtime = excluded.mtime,
                        size = excluded.size,
                        duration_ms = excluded.duration_ms,
                        width = excluded.width,
                        height = excluded.height,
                        fps = excluded.fps,
                        codec = excluded.codec,
                        audio_channels = excluded.audio_channels,
                        color_space = excluded.color_space,
                        created_at = COALESCE(sources.created_at, excluded.created_at),
                        online = 1
                """, arguments: [
                    url.path, hash, mtime, size,
                    meta.durationMs, meta.width, meta.height, meta.fps, meta.codec,
                    meta.audioChannels, meta.colorSpace, meta.createdAt, importedAt
                ])
                return try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM sources WHERE path = ?",
                    arguments: [url.path]
                ) ?? 0
            }

            // Kick off background thumbnail generation. Re-fetch the row so
            // the engine sees the latest hash without us juggling Source state.
            if let source: Source = try? database.read({ db in
                try Source.fetchOne(db, key: insertedID)
            }) {
                thumbnailEngine.generateThumbnail(source: source) { [weak self] _ in
                    guard let self else { return }
                    Task { await self.updateThumbPath(sourceID: insertedID) }
                }
            }

            scheduleRevisionBump()
        } catch {
            ClipxLog.indexer.error("indexFile failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func updateThumbPath(sourceID: Int64) async {
        do {
            let source: Source? = try database.read { db in
                try Source.fetchOne(db, key: sourceID)
            }
            guard let source else { return }
            let thumbURL = thumbnailEngine.thumbPath(for: source.hash)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE sources SET thumb_path = ? WHERE id = ?",
                    arguments: [thumbURL.path, sourceID]
                )
            }
            scheduleRevisionBump()
        } catch {
            ClipxLog.indexer.error("updateThumbPath failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Coalesces many per-file revisions into one MainActor bump per ~250ms.
    /// Without this, indexing a 5k folder fired 5k SwiftUI re-renders.
    private func scheduleRevisionBump() {
        pendingRevisionBump?.cancel()
        pendingRevisionBump = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AppState.shared.libraryRevision &+= 1
            }
            await self?.clearPendingBump()
        }
    }

    private func clearPendingBump() {
        pendingRevisionBump = nil
    }

    nonisolated private func collectVideoFiles(at root: URL) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard Indexer.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile else { continue }
            result.append(url)
        }
        return result
    }

    /// Marks all sources under the given folder as offline (drive unplugged).
    /// Escapes `_`/`%` so a folder like `My_Footage` doesn't match neighbours.
    func markFolderOffline(_ path: String) {
        let escaped = sqlLikeEscape(path)
        try? database.write { db in
            try db.execute(
                sql: "UPDATE sources SET online = 0 WHERE path LIKE ? ESCAPE '\\'",
                arguments: ["\(escaped)/%"]
            )
        }
        scheduleRevisionBump()
    }

    func markFolderOnline(_ path: String) {
        let escaped = sqlLikeEscape(path)
        try? database.write { db in
            try db.execute(
                sql: "UPDATE sources SET online = 1 WHERE path LIKE ? ESCAPE '\\'",
                arguments: ["\(escaped)/%"]
            )
        }
        scheduleRevisionBump()
    }
}
