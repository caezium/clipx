import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

/// Owns the bounded transcode queue and its cached results. A failed job stays
/// failed until an explicit retry; status polling never restarts failed work.
actor WebProxyEngine {
    static let targetHeight = 540
    static let maxFPS = 30

    struct Status {
        let ready: Bool
        let progress: Double
        let state: String
        let error: String?
    }
    private struct Job {
        let id: UUID
        let sourcePath: String
        let hash: String
        let rotation: Int
        var progress: Double = 0
        var state = "queued"
        var error: String?
        var task: Task<Void, Never>?
        var accessedAt = Date()
    }

    private let cacheDir: URL
    private let maxConcurrent: Int
    private let maxCacheBytes: Int64
    private var jobs: [String: Job] = [:]
    private var queued: [String] = []
    private var isShuttingDown = false

    init(cacheDir: URL? = nil, maxConcurrent: Int = 2, maxCacheBytes: Int64 = 1_073_741_824) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = cacheDir ?? AppPreferences.cacheDirectory?.appendingPathComponent("proxies", isDirectory: true)
            ?? caches.appendingPathComponent("Clipx/proxies", isDirectory: true)
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxCacheBytes = max(1, maxCacheBytes)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    /// Rotation changes rendered bytes; playback speed is applied by the browser
    /// so video.currentTime, seek positions and saved marks remain source time.
    nonisolated func proxyPath(forHash hash: String, rotation: Int = 0) -> URL {
        cacheDir.appendingPathComponent(Self.key(hash: hash, rotation: rotation) + ".mp4")
    }

    private nonisolated static func key(hash: String, rotation: Int) -> String {
        let identity = "v2:\(hash):\(VideoRotation.normalized(rotation))"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func status(forHash hash: String, rotation: Int = 0) -> Status {
        let url = proxyPath(forHash: hash, rotation: rotation)
        if Self.fileExistsNonEmpty(url) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return Status(ready: true, progress: 1, state: "ready", error: nil)
        }
        let key = Self.key(hash: hash, rotation: rotation)
        guard let job = jobs[key] else { return Status(ready: false, progress: 0, state: "idle", error: nil) }
        jobs[key]?.accessedAt = Date()
        return Status(ready: false, progress: job.progress, state: job.state, error: job.error)
    }

    func startProxyIfNeeded(sourcePath: String, hash: String, rotation: Int = 0, retry: Bool = false) {
        guard !Task.isCancelled, !isShuttingDown else { return }
        let key = Self.key(hash: hash, rotation: rotation)
        guard !Self.fileExistsNonEmpty(proxyPath(forHash: hash, rotation: rotation)) else { return }
        if let existing = jobs[key] {
            guard existing.state == "ready" || (retry && ["failed", "cancelled"].contains(existing.state)) else { return }
        }
        pruneFinishedJobs()
        guard queued.count < 32 else {
            jobs[key] = Job(id: UUID(), sourcePath: sourcePath, hash: hash, rotation: rotation,
                            state: "failed", error: "The preparation queue is full. Try again after another video finishes.")
            return
        }
        jobs[key] = Job(id: UUID(), sourcePath: sourcePath, hash: hash, rotation: rotation)
        queued.append(key)
        evictCache()
        runQueuedJobs()
    }

    /// Cancels all queued and running exports when Remote is disabled or the
    /// app shuts down. Drain each task before returning to its caller.
    func shutdown() async {
        isShuttingDown = true
        defer { isShuttingDown = false }
        queued.removeAll()
        let running = jobs.values.compactMap(\.task)
        for key in Array(jobs.keys) {
            jobs[key]?.task?.cancel()
            jobs[key]?.state = "cancelled"
            jobs[key]?.error = "Preparation was cancelled. Try again to restart it."
        }
        for task in running { await task.value }
    }

    private func runQueuedJobs() {
        while jobs.values.filter({ $0.task != nil }).count < maxConcurrent, !queued.isEmpty {
            let key = queued.removeFirst()
            guard let job = jobs[key], job.state == "queued" else { continue }
            jobs[key]?.state = "preparing"
            jobs[key]?.task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transcode(job: job, key: key)
                    await self.finish(key: key, id: job.id, error: nil)
                } catch {
                    await self.finish(key: key, id: job.id, error: error)
                }
            }
        }
    }

    private func finish(key: String, id: UUID, error: Error?) {
        guard jobs[key]?.id == id else { return }
        jobs[key]?.task = nil
        if let error {
            jobs[key]?.state = error is CancellationError ? "cancelled" : "failed"
            jobs[key]?.error = error is CancellationError
                ? "Preparation was cancelled. Try again to restart it."
                : "This video could not be prepared. Try again, or check that it plays on the Mac."
            ClipxLog.app.error("web proxy failed: \(String(describing: error), privacy: .public)")
        } else {
            jobs[key]?.state = "ready"
            jobs[key]?.progress = 1
            jobs[key]?.error = nil
        }
        evictCache()
        runQueuedJobs()
    }

    private func setProgress(key: String, id: UUID, value: Double) {
        guard jobs[key]?.id == id, jobs[key]?.state == "preparing" else { return }
        jobs[key]?.progress = value.isFinite ? min(1, max(0, value)) : 0
    }

    private func pruneFinishedJobs() {
        let finished = jobs.filter { $0.value.task == nil && $0.value.state != "queued" }
            .sorted { $0.value.accessedAt < $1.value.accessedAt }
        for (key, _) in finished.prefix(max(0, jobs.count - 127)) { jobs[key] = nil }
    }

    /// Keep at most a week's old previews and trim least-recently-used files
    /// above the disk budget. A five-minute grace keeps current playback stable.
    private func evictCache() {
        let fm = FileManager.default
        let now = Date()
        guard let urls = try? fm.contentsOfDirectory(at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let files = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let date = values.contentModificationDate ?? .distantPast
            if url.pathExtension != "mp4" {
                if url.lastPathComponent.contains(".partial-"), now.timeIntervalSince(date) > 86_400 {
                    try? fm.removeItem(at: url)
                }
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), date)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, date) in files where now.timeIntervalSince(date) > 300 {
            if total > maxCacheBytes || now.timeIntervalSince(date) > 7 * 86_400 {
                if (try? fm.removeItem(at: url)) != nil { total -= size }
            }
        }
    }

    private func transcode(job: Job, key: String) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: URL(fileURLWithPath: job.sourcePath))
        guard let composition = try await Self.buildDownscaleComposition(
            asset: asset, targetHeight: Self.targetHeight, maxFPS: Self.maxFPS, rotation: job.rotation
        ) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw CocoaError(.fileReadUnknown)
        }
        let dest = proxyPath(forHash: job.hash, rotation: job.rotation)
        // AVFoundation can attempt its final file open after the cancellation
        // completion has fired. Removing only the file can therefore leave a
        // recreated orphan. A private parent directory makes cleanup durable.
        let staging = cacheDir.appendingPathComponent(".partial-\(job.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let tmp = staging.appendingPathComponent("proxy.mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        session.outputURL = tmp
        session.outputFileType = .mp4
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.setProgress(key: key, id: job.id, value: Double(session.progress))
                do { try await Task.sleep(nanoseconds: 400_000_000) }
                catch { break }
            }
        }
        defer { poll.cancel() }
        let cancellation = ExportCancellation(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancellation.start(continuation)
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        // Only this generation can publish its output. No stale cleanup touches
        // a newer job's temporary path or final result.
        guard jobs[key]?.id == job.id else { throw CancellationError() }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func buildDownscaleComposition(
        asset: AVAsset, targetHeight: Int, maxFPS: Int, rotation: Int
    ) async throws -> AVMutableVideoComposition? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
        let oriented = bounds.size
        let rotated = VideoRotation.renderSize(oriented: oriented, degrees: rotation)
        guard rotated.width.isFinite, rotated.height.isFinite,
              rotated.width > 0, rotated.height > 0 else { return nil }
        let scale = min(1, CGFloat(targetHeight) / rotated.height)
        let dstW = max(2, ((rotated.width * scale / 2).rounded() * 2))
        let dstH = max(2, ((rotated.height * scale / 2).rounded() * 2))
        var transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        transform = transform.concatenating(VideoRotation.transform(oriented: oriented, degrees: rotation))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(
            translationX: (dstW - rotated.width * scale) / 2,
            y: (dstH - rotated.height * scale) / 2))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: dstW, height: dstH)
        let srcFPS = (try? await track.load(.nominalFrameRate)) ?? 30
        let fps = srcFPS.isFinite ? min(Float(maxFPS), max(1, srcFPS.rounded())) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.instructions = [instruction]
        return composition
    }

    private static func fileExistsNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 0
    }

    /// Only cancelExport crosses executors; all configuration and result reads
    /// remain on the engine actor. AVFoundation supports cancelling a running export.
    private final class ExportCancellation: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let lock = NSLock()
        private var cancelled = false
        init(_ session: AVAssetExportSession) { self.session = session }
        func start(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            session.exportAsynchronously { [self] in
                switch session.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: session.error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            session.cancelExport()
        }
    }
}
