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
    private let metadataLoader: (URL) async -> MetadataExtractor.VideoMeta
    private var pendingRevisionBump: Task<Void, Never>?
    private var deferredFiles: [String: URL] = [:]
    private var retryTask: Task<Void, Never>?
    private var inFlightPaths = Set<String>()
    private var generation = 0

    struct ScanResult {
        var scanned = 0
        var indexed = 0
        var failed = 0
        var deferred = 0
        var cancelled = false
    }
    private enum IndexOutcome { case indexed, unchanged, deferred, failed }
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

    init(database: Database, thumbnailEngine: ThumbnailEngine,
         metadataLoader: @escaping (URL) async -> MetadataExtractor.VideoMeta = MetadataExtractor.extract) {
        self.database = database
        self.thumbnailEngine = thumbnailEngine
        self.metadataLoader = metadataLoader
    }

    /// Scans the given root folder recursively for videos and indexes them.
    /// Calls `progress` periodically with (processed, total). Returns how many
    /// files were seen and how many were actually new/changed (written) so
    /// callers like "Rescan All" can report a meaningful result.
    @discardableResult
    func index(folder: URL, progress: ((Int, Int) -> Void)? = nil) async -> ScanResult {
        guard !Task.isCancelled else { return ScanResult(cancelled: true) }
        beginScan()
        defer { endScan() }
        let scanGeneration = generation
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            markFolderOffline(folder.path)
            return ScanResult(failed: 1)
        }
        let collection = collectVideoFiles(at: folder)
        guard !Task.isCancelled, scanGeneration == generation else { return ScanResult(cancelled: true) }
        var result = ScanResult(failed: collection.errors)
        for url in collection.urls {
            guard !Task.isCancelled, scanGeneration == generation else {
                result.cancelled = true
                return result
            }
            let outcome = await performIndex(url)
            guard !Task.isCancelled, scanGeneration == generation else {
                result.cancelled = true
                return result
            }
            switch outcome {
            case .indexed: result.indexed += 1
            case .failed: result.failed += 1
            case .deferred: result.deferred += 1
            case .unchanged: break
            }
            result.scanned += 1
            progress?(result.scanned, collection.urls.count)
        }
        guard !Task.isCancelled, scanGeneration == generation else {
            result.cancelled = true
            return result
        }
        _ = reconcileMissingSources(in: folder.path)
        do {
            try database.write { db in
                try db.execute(sql: "UPDATE folders SET online = 1, last_scan_at = ? WHERE path = ?",
                    arguments: [Int64(Date().timeIntervalSince1970), folder.path])
            }
        } catch { result.failed += 1 }
        return result
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
        await performIndex(url) == .indexed
    }

    func processFileEvent(_ url: URL) async -> Bool {
        let outcome = await performIndex(url)
        return outcome == .indexed || outcome == .unchanged
    }

    private func performIndex(_ url: URL) async -> IndexOutcome {
        guard !Task.isCancelled else { return .deferred }
        guard inFlightPaths.insert(url.path).inserted else {
            scheduleRetry(url)
            return .deferred
        }
        defer { inFlightPaths.remove(url.path) }
        let fileGeneration = generation
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
            let size = (attrs[.size] as? Int64) ?? 0

            // Don't index a file that's still being copied — its hash/duration
            // would be captured from truncated bytes and never corrected. (#20)
            let now = Int64(Date().timeIntervalSince1970)
            guard FileStability.isStable(mtimeEpoch: mtime, now: now) else {
                scheduleRetry(url)
                return .deferred
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
                    if existing.size == nil || !existing.online, let existingID = existing.id {
                        try database.write { db in
                            try db.execute(
                                sql: "UPDATE sources SET size = ?, online = 1 WHERE id = ?",
                                arguments: [size, existingID]
                            )
                        }
                        scheduleRevisionBump()
                        return .indexed
                    }
                    return .unchanged
                }
            }

            let hash = try FileHasher.quickHash(url: url)
            let meta = await metadataLoader(url)
            guard !Task.isCancelled, fileGeneration == generation else { return .deferred }
            let latest = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (latest[.size] as? Int64) == size,
                  (latest[.modificationDate] as? Date) == (attrs[.modificationDate] as? Date) else {
                scheduleRetry(url)
                return .deferred
            }
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
            return .indexed
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { markPathOffline(url.path) }
            ClipxLog.indexer.error("indexFile failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// A single retry loop handles any number of files still being copied.
    /// No new filesystem event is required once the last write settles.
    private func scheduleRetry(_ url: URL) {
        deferredFiles[url.path] = url
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_200_000_000) }
                catch { return }
                guard let self else { return }
                if !(await self.retryDeferredFiles()) { return }
            }
        }
    }

    private func retryDeferredFiles() async -> Bool {
        let files = Array(deferredFiles.values)
        deferredFiles.removeAll()
        for url in files {
            guard !Task.isCancelled else { return false }
            _ = await performIndex(url)
        }
        if deferredFiles.isEmpty { retryTask = nil; return false }
        return true
    }

    func cancelPendingWork() {
        generation &+= 1
        deferredFiles.removeAll()
        retryTask?.cancel()
        retryTask = nil
        pendingRevisionBump?.cancel()
        pendingRevisionBump = nil
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

    nonisolated private func collectVideoFiles(at root: URL) -> (urls: [URL], errors: Int) {
        var result: [URL] = []
        var errors = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in errors += 1; return true }
        ) else { return ([], 1) }
        var relativeComponents: [String] = []
        for case let url as URL in enumerator {
            relativeComponents = Array(relativeComponents.prefix(max(0, enumerator.level - 1)))
            relativeComponents.append(url.lastPathComponent)
            guard Indexer.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile else { continue }
            // Foundation enumerates canonical paths (/private/var on macOS),
            // but bookmarks and existing rows can retain an alias (/var).
            // Keep the chosen root's spelling so a rescan updates its rows.
            result.append(root.appendingPathComponent(relativeComponents.joined(separator: "/")))
        }
        return (result, errors)
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
    func reconcileMissingSources(in folder: String? = nil) -> Int {
        let sources: [Source] = (try? database.read { db in
            if let folder {
                let prefix = folderDescendantPrefix(folder)
                return try Source.fetchAll(db, sql: "SELECT * FROM sources WHERE online = 1 AND substr(path, 1, length(?)) = ? COLLATE BINARY",
                    arguments: [prefix, prefix])
            }
            return try Source.fetchAll(db, sql: "SELECT * FROM sources WHERE online = 1")
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
        let prefix = folderDescendantPrefix(path)
        try? database.write { db in
            try db.execute(sql: "UPDATE folders SET online = 0 WHERE path = ? COLLATE BINARY OR substr(path, 1, length(?)) = ? COLLATE BINARY",
                           arguments: [path, prefix, prefix])
            try db.execute(
                sql: "UPDATE sources SET online = 0 WHERE substr(path, 1, length(?)) = ? COLLATE BINARY",
                arguments: [prefix, prefix]
            )
        }
        scheduleRevisionBump()
    }

    func markFolderOnline(_ path: String) async {
        _ = await index(folder: URL(fileURLWithPath: path, isDirectory: true))
    }
}
