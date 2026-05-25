import Foundation
import AVFoundation
import CoreMedia

/// Sandbox-safe export backend used by the MAS build. Loses loudness
/// normalization and precise bitrate targeting, but works under sandbox
/// without bundled ffmpeg.
///
/// Cancellation: the caller registers a canceller closure via
/// `onCancellerRegistered`; ExportPipeline calls it from `cancelAll()` so the
/// in-flight `AVAssetExportSession` is actually cancelled (Swift task cancel
/// alone doesn't propagate to AVFoundation).
final class AVFoundationBackend {
    static func export(
        sourcePath: String,
        inMs: Int64,
        outMs: Int64,
        preset: ExportPreset,
        outputPath: String,
        onCancellerRegistered: ((@Sendable @escaping () -> Void) -> Void)? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))

        // Clamp out point to the actual asset duration; an off-by-one ms
        // rounding from clip storage used to push the time range past the
        // end and trigger a cryptic AVFoundation error.
        let durationSec = CMTimeGetSeconds(try await asset.load(.duration))
        let assetEndMs = Int64(durationSec * 1000)
        let clampedOutMs = min(max(inMs, outMs), assetEndMs > 0 ? assetEndMs : outMs)
        guard clampedOutMs > inMs else {
            throw NSError(domain: "clipx.export", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Empty time range after clamping to asset duration"])
        }

        let presetName = preset.height >= 2160 ? AVAssetExportPreset3840x2160 :
                         preset.height >= 1080 ? AVAssetExportPreset1920x1080 :
                                                 AVAssetExportPreset1280x720

        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw NSError(
                domain: "clipx.export",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create export session"]
            )
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        // AVAssetExportSession fails if outputURL already exists.
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(value: inMs, timescale: 1000),
            duration: CMTime(value: clampedOutMs - inMs, timescale: 1000)
        )

        // For vertical / square presets, attach a videoComposition that scales
        // + center-crops the source into the target render size. Without this
        // the AV backend just letterboxes inside the source aspect, and Reels
        // output didn't actually fit Reels — divergent from the ffmpeg path.
        if let composition = try? await Self.buildVideoComposition(
            asset: asset,
            renderWidth: preset.width,
            renderHeight: preset.height
        ) {
            session.videoComposition = composition
        }

        // Register a canceller that the pipeline can fire on cancelAll().
        onCancellerRegistered? { [weak session] in
            session?.cancelExport()
        }

        // Progress polling task — cancelled in defer regardless of outcome.
        let progressTask = Task {
            while session.status == .waiting || session.status == .exporting {
                onProgress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progressTask.cancel() }

        await session.export()

        switch session.status {
        case .completed:
            return
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw session.error ?? NSError(
                domain: "clipx.export", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Export ended with status \(session.status.rawValue)"]
            )
        }
    }

    /// Builds a videoComposition that scales-and-pads the source video into a
    /// target render size while preserving aspect ratio (center-crop on
    /// short axis, letterbox on long axis). Returns nil if the source has no
    /// video track.
    private static func buildVideoComposition(
        asset: AVAsset,
        renderWidth: Int,
        renderHeight: Int
    ) async throws -> AVMutableVideoComposition? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return nil }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        let srcW = abs(oriented.width)
        let srcH = abs(oriented.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let dstW = CGFloat(renderWidth)
        let dstH = CGFloat(renderHeight)
        let scale = max(dstW / srcW, dstH / srcH)
        let scaledW = srcW * scale
        let scaledH = srcH * scale
        let translateX = (dstW - scaledW) / 2
        let translateY = (dstH - scaledH) / 2

        var t = transform
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: translateX, y: translateY))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(t, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: dstW, height: dstH)
        let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, Int(frameRate.rounded()))))
        composition.instructions = [instruction]
        return composition
    }
}
