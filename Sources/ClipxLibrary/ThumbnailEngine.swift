import Foundation
import AVFoundation
import AppKit
import CryptoKit
import GRDB

/// Generates and caches thumbnails (single frame + hover sprite strip) for sources.
/// Uses AVAssetImageGenerator under a serial dispatch queue, semaphore-limited
/// to 4 concurrent requests so the UI thread stays responsive.
///
/// In-flight dedup: when a card view requests a thumbnail that's already being
/// generated, we just register the new completion callback against the
/// existing request instead of dispatching a duplicate Task. Without this,
/// scrolling a long list could queue hundreds of redundant generations and
/// flood main with completion handlers.
final class ThumbnailEngine {
    private let database: Database
    private let cacheDir: URL
    private let queue = DispatchQueue(
        label: "com.clipx.thumbnails",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let semaphore = DispatchSemaphore(value: 4)
    /// Hash → pending completion handlers. Protected by `inFlightLock`.
    private var inFlight: [String: [(URL?) -> Void]] = [:]
    private let inFlightLock = NSLock()

    init(database: Database) {
        self.database = database
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
        let loadGroup = DispatchSemaphore(value: 0)
        var duration: Double = 0
        var loadOK = false
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "duration", error: &error)
            if status == .loaded {
                duration = CMTimeGetSeconds(asset.duration)
                loadOK = duration > 0 && duration.isFinite
            }
            loadGroup.signal()
        }
        // 8s ceiling per asset — networked / corrupt files won't permanently
        // block a slot.
        let waitResult = loadGroup.wait(timeout: .now() + .seconds(8))
        guard waitResult == .success, loadOK else {
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
    func generateSprite(source: Source, frameCount: Int = 10, completion: @escaping (URL?) -> Void) {
        let target = spritePath(for: source.hash)
        if FileManager.default.fileExists(atPath: target.path) {
            completion(target)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { completion(nil); return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }

            let asset = AVURLAsset(url: source.url)
            let duration: Double
            do {
                let cm = try await asset.load(.duration)
                duration = CMTimeGetSeconds(cm)
            } catch {
                await MainActor.run { completion(nil) }
                return
            }
            guard duration > 0 else { await MainActor.run { completion(nil) }; return }
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
                guard let bitmap = bitmap else { completion(nil); return }

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
                DispatchQueue.main.async { completion(target) }
            }
        }
    }

    /// Removes cached thumbnails — used by Settings "Clear cache" button.
    func clearCache() throws {
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
