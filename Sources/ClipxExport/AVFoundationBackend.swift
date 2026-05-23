import Foundation
import AVFoundation

/// Sandbox-safe export backend used by the MAS build. Loses loudness
/// normalization and precise bitrate targeting, but works under sandbox
/// without bundled ffmpeg.
final class AVFoundationBackend {
    static func export(
        sourcePath: String,
        inMs: Int64,
        outMs: Int64,
        preset: ExportPreset,
        outputPath: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
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
        session.outputURL = URL(fileURLWithPath: outputPath)
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(value: inMs, timescale: 1000),
            duration: CMTime(value: outMs - inMs, timescale: 1000)
        )

        // Progress polling task
        let progressTask = Task {
            while session.status == .waiting || session.status == .exporting {
                onProgress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progressTask.cancel() }

        await session.export()

        if session.status != .completed {
            throw session.error ?? NSError(
                domain: "clipx.export", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Export ended with status \(session.status.rawValue)"]
            )
        }
    }
}
