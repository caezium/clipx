import Foundation
import AVFoundation
import AppKit
import CryptoKit

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
    func generateThumbnail(source: Source, completion: @escaping (URL?) -> Void) {
        let target = thumbPath(for: source.hash)
        if FileManager.default.fileExists(atPath: target.path) {
            completion(target)
            return
        }
        let hash = source.hash

        // Dedup: if a generation for this hash is already in flight, just
        // register our completion and return.
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

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { fanout(nil); return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }

            let asset = AVURLAsset(url: source.url)
            let duration: Double
            do {
                let cm = try await asset.load(.duration)
                duration = CMTimeGetSeconds(cm)
            } catch {
                fanout(nil)
                return
            }
            autoreleasepool {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                let seekTime = CMTime(seconds: max(0.5, duration * 0.1), preferredTimescale: 600)
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
}
