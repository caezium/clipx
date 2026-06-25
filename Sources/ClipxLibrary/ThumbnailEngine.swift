import Foundation
import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import GRDB

/// One-shot box to hand an async-loaded value back across a semaphore bridge.
/// `@unchecked Sendable` is sound here because the DispatchSemaphore establishes
/// the happens-before between the Task's write and the waiter's read.
private final class DurationResultBox: @unchecked Sendable {
    var seconds: Double?
}

/// Generates and caches thumbnails (single frame + hover sprite strip) for sources.
/// Uses AVAssetImageGenerator under a serial dispatch queue, semaphore-limited
/// to 4 concurrent requests so the UI thread stays responsive.
///
/// In-flight dedup: when a card view requests a thumbnail that's already being
/// generated, we just register the new completion callback against the
/// existing request instead of dispatching a duplicate Task. Without this,
/// scrolling a long list could queue hundreds of redundant generations and
/// flood main with completion handlers.
/// Minimal source identity a card needs to show a thumbnail, without decoding
/// the whole `Source` row. Memoized by `ThumbnailEngine.sourceThumbMeta`.
struct SourceThumbMeta {
    let hash: String
    let path: String
    let displayName: String
}

final class ThumbnailEngine {
    private let database: Database
    private let cacheDir: URL
    private let queue = DispatchQueue(
        label: "com.clipx.thumbnails",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Concurrency cap on AVAssetImageGenerator work. Scaled to the machine so a
    /// dual-core laptop isn't oversubscribed by 4 simultaneous video decodes
    /// while an 8-core desktop still parallelises. Was a fixed `4`.
    private let semaphore = DispatchSemaphore(
        value: max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    )
    /// Hash → pending completion handlers. Protected by `inFlightLock`.
    private var inFlight: [String: [(URL?) -> Void]] = [:]
    private let inFlightLock = NSLock()

    /// In-memory decoded-thumbnail cache, keyed by source hash. Lets a card that
    /// scrolls back into view paint instantly instead of re-reading the JPEG off
    /// disk and re-decoding it every time LazyVGrid recycles the view. NSCache
    /// is thread-safe and self-evicts under memory pressure.
    private let imageCache = NSCache<NSString, NSImage>()
    /// sourceID → (hash, path, name), so a clip card doesn't run a SQLite query
    /// on every `onAppear`. Many clips share one source, so this collapses
    /// N-per-scroll reads to one read per distinct source. Protected by `metaLock`.
    private var metaCache: [Int64: SourceThumbMeta] = [:]
    private let metaLock = NSLock()

    init(database: Database) {
        self.database = database
        // Bound the cache so a huge library can't grow it without limit; NSCache
        // also drops entries automatically when the system needs memory.
        imageCache.countLimit = 600
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = caches.appendingPathComponent("Clipx/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Path where a single representative thumb should be cached for a hash.
    func thumbPath(for hash: String) -> URL {
        cacheDir.appendingPathComponent("\(hash).jpg")
    }

    /// Path where a hover sprite strip should be cached for a hash.
    func spritePath(for hash: String) -> URL {
        cacheDir.appendingPathComponent("\(hash)-sprite.jpg")
    }

    // MARK: - Display image cache (memory-cached, downsampled)

    /// Memoized minimal source identity for a clip card. First call hits SQLite
    /// for just `hash` + `path`; subsequent calls (incl. scroll recycles and the
    /// many clips sharing one source) return from memory.
    func sourceThumbMeta(for sourceID: Int64) -> SourceThumbMeta? {
        metaLock.lock()
        if let cached = metaCache[sourceID] {
            metaLock.unlock()
            return cached
        }
        metaLock.unlock()

        guard let row = try? database.read({ db in
            try Row.fetchOne(
                db, sql: "SELECT hash, path FROM sources WHERE id = ?", arguments: [sourceID]
            )
        }), let hash: String = row["hash"], let path: String = row["path"] else {
            return nil
        }
        let meta = SourceThumbMeta(
            hash: hash, path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
        metaLock.lock()
        metaCache[sourceID] = meta
        metaLock.unlock()
        return meta
    }

    /// Synchronous in-memory cache probe — nil on miss. Safe from any thread.
    func cachedImage(forHash hash: String) -> NSImage? {
        imageCache.object(forKey: hash as NSString)
    }

    /// Drops the memoized identity for a source — call after re-indexing so a
    /// card picks up a changed hash (and thus a freshly generated thumbnail)
    /// instead of the stale cached one.
    func invalidateSourceMeta(_ sourceID: Int64) {
        metaLock.lock()
        metaCache[sourceID] = nil
        metaLock.unlock()
    }

    /// Returns a display-ready thumbnail: decoded at `maxPixel` (the card's pixel
    /// size, not the full 480px cache file) and held in an in-memory cache.
    /// Generates the on-disk thumb first if it's missing. Completion always
    /// fires on the main queue.
    ///
    /// This is the path card views should use — it removes the per-appear disk
    /// read + full-size JPEG decode that made scrolling a big grid stutter on
    /// low-spec machines.
    func displayThumbnail(
        forHash hash: String, sourcePath: String, maxPixel: Int,
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = imageCache.object(forKey: hash as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        let cacheURL = thumbPath(for: hash)
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            // Fast path: thumb already on disk — decode it downsampled and cache.
            if let img = Self.downsampledImage(at: cacheURL, maxPixel: maxPixel) {
                self.imageCache.setObject(img, forKey: hash as NSString)
                DispatchQueue.main.async { completion(img) }
                return
            }
            // Disk miss (never generated, or cache purged by macOS) — generate,
            // then load the result downsampled.
            let stub = Source(
                id: nil, path: sourcePath, bookmark: nil, hash: hash, mtime: 0,
                durationMs: nil, width: nil, height: nil, fps: nil, codec: nil,
                audioChannels: nil, colorSpace: nil, createdAt: nil,
                importedAt: 0, thumbPath: nil, online: true, notes: nil
            )
            self.generateThumbnail(source: stub) { [weak self] resultURL in
                guard let self, let resultURL else { completion(nil); return }
                // generateThumbnail de-dupes concurrent requests for one hash, so
                // many cards sharing a source wake here together — re-probe the
                // cache so only the first decodes the freshly generated JPEG.
                if let warm = self.imageCache.object(forKey: hash as NSString) {
                    DispatchQueue.main.async { completion(warm) }
                    return
                }
                self.queue.async {
                    if let warm = self.imageCache.object(forKey: hash as NSString) {
                        DispatchQueue.main.async { completion(warm) }
                        return
                    }
                    let img = Self.downsampledImage(at: resultURL, maxPixel: maxPixel)
                    if let img { self.imageCache.setObject(img, forKey: hash as NSString) }
                    DispatchQueue.main.async { completion(img) }
                }
            }
        }
    }

    /// Decodes an image file directly to a thumbnail no larger than `maxPixel` on
    /// its longest edge, using ImageIO so we never materialize the full-size
    /// bitmap. Returns nil if the file is missing or undecodable.
    static func downsampledImage(at url: URL, maxPixel: Int) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Generates a single representative thumbnail at ~10% into the source.
    /// Returns the cache file URL or nil if generation failed. De-dupes
    /// concurrent requests for the same hash.
    ///
    /// Runs on a real DispatchQueue, not the Swift cooperative pool.
    /// Previously this used `Task.detached` + `DispatchSemaphore.wait()`,
    /// which is the classic deadlock pattern — blocking a cooperative thread
    /// starves the pool. With 100+ pending requests, the pool died and
    /// nothing finished after the first ~4 grabs.
    func generateThumbnail(source: Source, completion: @escaping (URL?) -> Void) {
        let target = thumbPath(for: source.hash)
        if FileManager.default.fileExists(atPath: target.path) {
            completion(target)
            return
        }
        let hash = source.hash

        inFlightLock.lock()
        if inFlight[hash] != nil {
            inFlight[hash]?.append(completion)
            inFlightLock.unlock()
            return
        }
        inFlight[hash] = [completion]
        inFlightLock.unlock()

        let fanout: (URL?) -> Void = { [weak self] result in
            guard let self else { return }
            self.inFlightLock.lock()
            let completions = self.inFlight.removeValue(forKey: hash) ?? []
            self.inFlightLock.unlock()
            DispatchQueue.main.async {
                for cb in completions { cb(result) }
            }
        }

        queue.async { [weak self] in
            guard let self else { fanout(nil); return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }
            self.generateSync(source: source, target: target, fanout: fanout)
        }
    }

    /// Synchronous body of thumbnail generation — safe to call from a real
    /// dispatch queue. Uses `loadValuesAsynchronously` + a per-call
    /// DispatchSemaphore for the async-to-sync bridge, with a hard timeout
    /// so a single bad asset can't permanently consume one of our 4
    /// concurrent slots.
    private func generateSync(source: Source, target: URL, fanout: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: source.url)
        // Load duration via the modern async API (replaces the deprecated
        // loadValuesAsynchronously + statusOfValue + asset.duration), bridged
        // back to this real dispatch queue with a semaphore. 8s ceiling per
        // asset so networked / corrupt files can't permanently hold one of our
        // 4 slots. The load runs on the cooperative pool and only signals; this
        // (real, non-cooperative) dispatch thread is the one that blocks, so the
        // pool is never starved.
        let loadGroup = DispatchSemaphore(value: 0)
        let box = DurationResultBox()
        Task {
            box.seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            loadGroup.signal()
        }
        guard loadGroup.wait(timeout: .now() + .seconds(8)) == .success,
              let duration = box.seconds, duration > 0, duration.isFinite else {
            fanout(nil)
            return
        }
        autoreleasepool {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let seekTime = CMTime(
                seconds: max(0.5, duration * 0.1),
                preferredTimescale: 600
            )
            do {
                let cgImage = try generator.copyCGImage(at: seekTime, actualTime: nil)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                try data?.write(to: target)
                fanout(target)
            } catch {
                fanout(nil)
            }
        }
    }

    /// Generates a horizontal sprite strip of N frames for hover-scrubbing preview.
    ///
    /// Runs on a real DispatchQueue, not the Swift cooperative pool — same
    /// reasoning as `generateThumbnail`. Previously this ran its whole body in
    /// `Task.detached` and called `DispatchSemaphore.wait()` on that cooperative
    /// thread: the classic pool-starvation deadlock (and a hard error under the
    /// Swift 6 language mode, where `wait()` is unavailable from async contexts).
    func generateSprite(source: Source, frameCount: Int = 10, completion: @escaping (URL?) -> Void) {
        let target = spritePath(for: source.hash)
        if FileManager.default.fileExists(atPath: target.path) {
            completion(target)
            return
        }
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }
            self.generateSpriteSync(
                source: source, frameCount: frameCount, target: target, completion: completion
            )
        }
    }

    /// Synchronous body of sprite-strip generation — safe to call from a real
    /// dispatch queue. Bridges the async duration load back to this thread with
    /// a DispatchSemaphore + 8s timeout (same pattern as `generateSync`), so the
    /// load runs on the cooperative pool and only signals while this real,
    /// non-cooperative thread blocks — the pool is never starved. Completion
    /// always fires on main.
    private func generateSpriteSync(
        source: Source, frameCount: Int, target: URL, completion: @escaping (URL?) -> Void
    ) {
        let finish: (URL?) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        let asset = AVURLAsset(url: source.url)
        let loadGroup = DispatchSemaphore(value: 0)
        let box = DurationResultBox()
        Task {
            box.seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            loadGroup.signal()
        }
        guard loadGroup.wait(timeout: .now() + .seconds(8)) == .success,
              let duration = box.seconds, duration > 0, duration.isFinite else {
            finish(nil)
            return
        }
        autoreleasepool {
            let frameW = 240, frameH = 135
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: frameW, height: frameH)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: frameW * frameCount,
                pixelsHigh: frameH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 32
            )
            guard let bitmap = bitmap else { finish(nil); return }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            for i in 0..<frameCount {
                let t = duration * Double(i) / Double(frameCount - 1)
                let time = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                    let rect = CGRect(x: CGFloat(i * frameW), y: 0,
                                      width: CGFloat(frameW), height: CGFloat(frameH))
                    let image = NSImage(cgImage: cg, size: rect.size)
                    image.draw(in: rect)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            try? data?.write(to: target)
            finish(target)
        }
    }

    /// Removes cached thumbnails — used by Settings "Clear cache" button.
    func clearCache() throws {
        imageCache.removeAllObjects()
        try FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// One-shot background pass that generates thumbnails for every source
    /// that doesn't have a cache file yet. Called from
    /// `AppEnvironment.bootstrap()` after the watcher resumes so the user
    /// doesn't have to scroll every card into view to populate thumbnails.
    /// Sources offline at scan time are skipped.
    func primeMissingThumbnails() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            // Pull just the columns we need. Avoids decoding every Source row
            // for a check we can do on hash + path alone.
            let candidates: [(hash: String, path: String, sourceID: Int64)]
            do {
                candidates = try self.database.read { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT id, hash, path FROM sources WHERE online = 1"
                    ).compactMap { row in
                        guard let hash: String = row["hash"],
                              let path: String = row["path"],
                              let id: Int64 = row["id"] else { return nil }
                        return (hash, path, id)
                    }
                }
            } catch {
                ClipxLog.library.error("primeMissingThumbnails read failed: \(String(describing: error), privacy: .public)")
                return
            }
            var generated = 0
            for cand in candidates {
                let target = self.thumbPath(for: cand.hash)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                guard FileManager.default.fileExists(atPath: cand.path) else { continue }
                // Synthesize a minimal Source so generateThumbnail can
                // use the URL + hash. The full record isn't needed.
                let stub = Source(
                    id: cand.sourceID, path: cand.path, bookmark: nil,
                    hash: cand.hash, mtime: 0, durationMs: nil,
                    width: nil, height: nil, fps: nil, codec: nil,
                    audioChannels: nil, colorSpace: nil, createdAt: nil,
                    importedAt: 0, thumbPath: nil, online: true, notes: nil
                )
                // Fire-and-forget — dedup cache (in generateThumbnail) means
                // a concurrent card view request for the same hash just
                // hitches a ride.
                self.generateThumbnail(source: stub) { _ in }
                generated += 1
            }
            ClipxLog.library.info("primeMissingThumbnails queued \(generated) of \(candidates.count) sources")
        }
    }
}
