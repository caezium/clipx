import Foundation
import AVFoundation
import CoreMedia

/// Generates and caches small, aggressively-compressed web proxies of source
/// videos so the phone / laptop browser can stream them over Wi-Fi. Raw DJI
/// 1080p50 onboard footage is tens of Mbps — unusable remotely. The proxy is
/// ~540p, capped at 30fps, re-encoded H.264 at a low bitrate (roughly 1/20th
/// the size), and stored at ~/Library/Caches/Clipx/proxies/<hash>.mp4.
///
/// An `actor` so the in-flight job table and progress map are race-free. The
/// heavy `AVAssetExportSession.export()` awaits suspend the actor, leaving it
/// free to answer status queries while a transcode runs.
actor WebProxyEngine {
    /// Target proxy height (px). 540p is plenty for phone review and a big cut
    /// from 1080p. Drop to 480/360 here if footage still feels heavy.
    static let targetHeight = 540
    /// Cap frame rate — DJI shoots 50/60fps; 30 is smooth for review and
    /// roughly halves the bitrate.
    static let maxFPS = 30

    private let cacheDir: URL
    /// One transcode per source hash; concurrent requests share the job.
    private var jobs: [String: Task<URL, Error>] = [:]
    /// 0...1 transcode progress per hash, for the status endpoint.
    private var progressByHash: [String: Double] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = caches.appendingPathComponent("Clipx/proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    nonisolated func proxyPath(forHash hash: String) -> URL {
        cacheDir.appendingPathComponent("\(hash).mp4")
    }

    /// (ready, progress). `ready` means a finished proxy file exists on disk.
    func status(forHash hash: String) -> (ready: Bool, progress: Double) {
        if Self.fileExistsNonEmpty(proxyPath(forHash: hash)) { return (true, 1.0) }
        if jobs[hash] != nil { return (false, max(0.01, progressByHash[hash] ?? 0)) }
        return (false, 0)
    }

    /// Kicks off a transcode if the proxy isn't already ready / building.
    /// Fire-and-forget: returns immediately so the HTTP handler never blocks
    /// for the length of a transcode.
    func startProxyIfNeeded(sourcePath: String, hash: String) {
        let dest = proxyPath(forHash: hash)
        if Self.fileExistsNonEmpty(dest) || jobs[hash] != nil { return }
        progressByHash[hash] = 0
        let job = Task<URL, Error> {
            try await self.transcode(sourcePath: sourcePath, hash: hash, dest: dest)
        }
        jobs[hash] = job
        // Reap the job entry once it finishes, regardless of outcome.
        Task {
            _ = try? await job.value
            await self.clearJob(hash: hash)
        }
    }

    private func clearJob(hash: String) {
        jobs[hash] = nil
        if Self.fileExistsNonEmpty(proxyPath(forHash: hash)) {
            progressByHash[hash] = 1.0
        } else {
            progressByHash[hash] = nil
        }
    }

    private func setProgress(hash: String, value: Double) {
        // Don't let polling clobber a finished entry.
        if jobs[hash] != nil { progressByHash[hash] = value }
    }

    // MARK: - Transcode

    private func transcode(sourcePath: String, hash: String, dest: URL) async throws -> URL {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))

        guard let composition = try await Self.buildDownscaleComposition(
            asset: asset, targetHeight: Self.targetHeight, maxFPS: Self.maxFPS
        ) else {
            throw NSError(domain: "clipx.proxy", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Source has no video track"])
        }

        // MediumQuality is a quality-based preset, so the encoder picks a
        // bitrate appropriate to the small 540p render size — far smaller than a
        // resolution preset tuned for full-res output.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw NSError(domain: "clipx.proxy", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create export session"])
        }

        // Write to a temp file and atomically move on success so the status
        // check (file exists) never sees a half-written proxy.
        let tmp = dest.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        session.outputURL = tmp
        session.outputFileType = .mp4
        session.videoComposition = composition
        // Move the moov atom to the front so the browser can start playing
        // before the whole file downloads (progressive streaming).
        session.shouldOptimizeForNetworkUse = true

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.setProgress(hash: hash, value: Double(session.progress))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        await session.export()
        poll.cancel()

        switch session.status {
        case .completed:
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            ClipxLog.app.info("web proxy ready for \(hash, privacy: .public)")
            return dest
        case .cancelled:
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: tmp)
            throw session.error ?? NSError(
                domain: "clipx.proxy", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Transcode ended with status \(session.status.rawValue)"]
            )
        }
    }

    /// Builds a composition that scales the source to `targetHeight` (preserving
    /// aspect, even dimensions for H.264) and caps the frame rate. Returns nil
    /// when the asset has no video track.
    private static func buildDownscaleComposition(
        asset: AVAsset, targetHeight: Int, maxFPS: Int
    ) async throws -> AVMutableVideoComposition? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = natural.applying(transform)
        let srcW = abs(oriented.width), srcH = abs(oriented.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = CGFloat(targetHeight) / srcH
        // Even dimensions — H.264 requires it.
        let dstH = CGFloat(targetHeight)
        let dstW = (((srcW * scale) / 2).rounded() * 2)
        let scaledW = srcW * scale
        let scaledH = srcH * scale

        var t = transform
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(
            translationX: (dstW - scaledW) / 2,
            y: (dstH - scaledH) / 2
        ))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layer]

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: dstW, height: dstH)
        let srcFPS = (try? await track.load(.nominalFrameRate)) ?? 30
        let fps = min(maxFPS, max(24, Int(srcFPS.rounded())))
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        comp.instructions = [instruction]
        return comp
    }

    private static func fileExistsNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 0
    }
}
