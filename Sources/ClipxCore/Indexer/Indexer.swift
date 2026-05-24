import Foundation
import GRDB

/// Walks a folder, extracts metadata for each video file, and writes Source
/// records. Idempotent: re-indexing the same file updates rather than dupes.
@MainActor
final class Indexer {
    private let database: Database
    private let thumbnailEngine: ThumbnailEngine
    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "mts", "m2ts",
        "webm", "wmv", "flv", "hevc", "prores"
    ]

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
            let hash = try FileHasher.quickHash(url: url)

            // Idempotent insert/update.
            let existing: Source? = try database.read { db in
                try Source.filter(Source.Columns.path == url.path).fetchOne(db)
            }
            if let existing, existing.mtime == mtime { return } // unchanged

            let meta = await MetadataExtractor.extract(url: url)
            var source = existing ?? Source(
                id: nil,
                path: url.path,
                bookmark: nil,
                hash: hash,
                mtime: mtime,
                durationMs: meta.durationMs,
                width: meta.width,
                height: meta.height,
                fps: meta.fps,
                codec: meta.codec,
                audioChannels: meta.audioChannels,
                colorSpace: meta.colorSpace,
                createdAt: meta.createdAt,
                importedAt: Int64(Date().timeIntervalSince1970),
                thumbPath: nil,
                online: true,
                notes: nil
            )
            source.mtime = mtime
            source.hash = hash
            source.durationMs = meta.durationMs
            source.width = meta.width
            source.height = meta.height
            source.fps = meta.fps
            source.codec = meta.codec
            source.audioChannels = meta.audioChannels
            source.colorSpace = meta.colorSpace
            source.online = true

            try database.write { db in
                if source.id == nil { try source.insert(db) } else { try source.update(db) }
            }
            AppState.shared.libraryRevision &+= 1

            // Kick off background thumbnail generation.
            thumbnailEngine.generateThumbnail(source: source) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.updateThumbPath(sourceID: source.id!)
                    AppState.shared.libraryRevision &+= 1
                }
            }
        } catch {
            NSLog("Indexer.indexFile failed for \(url.path): \(error)")
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
        } catch {
            NSLog("Indexer.updateThumbPath failed: \(error)")
        }
    }

    private func collectVideoFiles(at root: URL) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile else { continue }
            result.append(url)
        }
        return result
    }

    /// Marks all sources under the given folder as offline (drive unplugged).
    func markFolderOffline(_ path: String) {
        try? database.write { db in
            try db.execute(
                sql: "UPDATE sources SET online = 0 WHERE path LIKE ?",
                arguments: ["\(path)/%"]
            )
        }
    }

    func markFolderOnline(_ path: String) {
        try? database.write { db in
            try db.execute(
                sql: "UPDATE sources SET online = 1 WHERE path LIKE ?",
                arguments: ["\(path)/%"]
            )
        }
    }
}
