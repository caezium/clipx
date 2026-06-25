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
    /// How many bulk scans are in flight. While > 0 a slow per-file heartbeat
    /// drives the UI instead of one debounced reload per written file.
    private var scanDepth = 0
    /// Set whenever a scan actually writes something. The heartbeat only fires a
    /// refresh when this is set, so a "Rescan All" over an unchanged folder
    /// (zero new rows) stays quiet instead of reloading every view every tick.
    private var scanDirty = false
    /// Periodic library-refresh while a bulk scan runs.
    private var scanHeartbeat: Task<Void, Never>?
    /// Refresh cadence during a bulk scan. On a low-spec machine each file can
    /// take longer than the interactive 250ms debounce, which previously turned
    /// "one reload per file" into a continuous full-library re-query during an
    /// import. A coarse heartbeat caps that to one reload per interval.
    private static let scanHeartbeatNs: UInt64 = 1_500_000_000   // 1.5s

    init(database: Database, thumbnailEngine: ThumbnailEngine) {
        self.database = database
        self.thumbnailEngine = thumbnailEngine
    }

    /// Scans the given root folder recursively for videos and indexes them.
    /// Calls `progress` periodically with (processed, total). Returns how many
    /// files were seen and how many were actually new/changed (written) so
    /// callers like "Rescan All" can report a meaningful result.
    @discardableResult
    func index(folder: URL, progress: ((Int, Int) -> Void)? = nil) async -> (scanned: Int, indexed: Int) {
        beginScan()
        defer { endScan() }
        let urls = collectVideoFiles(at: folder)
        let total = urls.count
        var processed = 0
        var indexed = 0
        for url in urls {
            if await indexFile(url) { indexed += 1 }
            processed += 1
            progress?(processed, total)
        }
        return (scanned: total, indexed: indexed)
    }

    // MARK: - Scan lifecycle (controls UI-refresh cadence)

    private func beginScan() {
        scanDepth += 1
        guard scanDepth == 1 else { return }
        // The heartbeat owns the cadence now — drop any pending interactive bump.
        pendingRevisionBump?.cancel()
        pendingRevisionBump = nil
        scanDirty = false
        scanHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Indexer.scanHeartbeatNs)
                if Task.isCancelled { break }
                // Only refresh if something was written since the last tick.
                guard let self, await self.consumeScanDirty() else { continue }
                await MainActor.run { AppState.shared.libraryRevision &+= 1 }
            }
        }
    }

    private func endScan() {
        scanDepth = max(0, scanDepth - 1)
        guard scanDepth == 0 else { return }
        scanHeartbeat?.cancel()
        scanHeartbeat = nil
        // Final refresh only if files were indexed since the last heartbeat.
        if scanDirty {
            scanDirty = false
            Task { @MainActor in AppState.shared.libraryRevision &+= 1 }
        }
    }

    /// Reads and clears the scan-dirty flag in one actor-isolated step.
    private func consumeScanDirty() -> Bool {
        defer { scanDirty = false }
        return scanDirty
    }

    /// Indexes a single file. Returns `true` if it wrote a new/updated row,
    /// `false` if the file was unchanged (skipped) or failed.
    @discardableResult
    func indexFile(_ url: URL) async -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
            let size = (attrs[.size] as? Int64) ?? 0

            // Don't index a file that's still being copied — its hash/duration
            // would be captured from truncated bytes and never corrected. (#20)
            let now = Int64(Date().timeIntervalSince1970)
            guard FileStability.isStable(mtimeEpoch: mtime, now: now) else {
                return false
            }

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
                    return false
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

            // A re-index may have changed the hash — drop the memoized identity
            // so cards re-resolve to the new hash / freshly generated thumb.
            thumbnailEngine.invalidateSourceMeta(insertedID)

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
            return true
        } catch {
            ClipxLog.indexer.error("indexFile failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
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
    ///
    /// During a bulk scan (`scanDepth > 0`) the heartbeat owns the refresh
    /// cadence, so per-file bumps are suppressed — otherwise a slow machine
    /// whose per-file work exceeds 250ms reloads the whole library once per file.
    private func scheduleRevisionBump() {
        guard scanDepth == 0 else {
            // A scan is running — record that there's something to show and let
            // the heartbeat fire the refresh on its own cadence.
            scanDirty = true
            return
        }
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

    /// One-time pass: derive each source's recording date from its filename
    /// (the true shoot date for DJI / action-cam footage) wherever the name
    /// carries one. Fixes sources that indexed with a missing or copy-date
    /// `created_at` — the cause of footage landing under "No recording date".
    /// Returns the number of rows updated.
    @discardableResult
    func backfillFilenameDates() async -> Int {
        let sources: [Source] = (try? database.read { db in
            try Source.fetchAll(db)
        }) ?? []
        var updated = 0
        for src in sources {
            guard let id = src.id else { continue }
            let name = URL(fileURLWithPath: src.path).lastPathComponent
            guard let parsed = FilenameDateParser.parse(name), src.createdAt != parsed else { continue }
            do {
                try database.write { db in
                    try db.execute(
                        sql: "UPDATE sources SET created_at = ? WHERE id = ?",
                        arguments: [parsed, id]
                    )
                }
                updated += 1
            } catch {
                ClipxLog.indexer.error("backfillFilenameDates failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if updated > 0 { scheduleRevisionBump() }
        return updated
    }

    /// Marks every online source whose backing file no longer exists as
    /// offline, so renamed / moved / deleted files stop showing as available.
    /// Returns the number of rows changed. (#21)
    @discardableResult
    func reconcileMissingSources() -> Int {
        let sources: [Source] = (try? database.read { db in
            try Source.fetchAll(db, sql: "SELECT * FROM sources WHERE online = 1")
        }) ?? []
        var changed = 0
        for src in sources where !FileManager.default.fileExists(atPath: src.path) {
            guard let id = src.id else { continue }
            try? database.write { db in
                try db.execute(sql: "UPDATE sources SET online = 0 WHERE id = ?", arguments: [id])
            }
            changed += 1
        }
        if changed > 0 { scheduleRevisionBump() }
        return changed
    }

    /// Marks a single source offline by path — used when the watcher sees a
    /// remove event for a known file. (#21)
    func markPathOffline(_ path: String) {
        try? database.write { db in
            try db.execute(sql: "UPDATE sources SET online = 0 WHERE path = ?", arguments: [path])
        }
        scheduleRevisionBump()
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
