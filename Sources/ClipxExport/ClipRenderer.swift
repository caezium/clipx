import AVFoundation
import Darwin
import Foundation

/// The complete, immutable render operation used by export, drag, and review.
struct ClipRenderRequest: Sendable {
    let sourcePath: String
    let inMs: Int64
    let outMs: Int64
    let rotation: Int
    let speed: Double
    let preset: ExportPreset
    let outputURL: URL

    var expectedDurationSeconds: Double { Double(outMs - inMs) / 1000 / speed }

    init(clip: Clip, source: Source, preset: ExportPreset, outputURL: URL) throws {
        guard clip.inMs >= 0, clip.outMs > clip.inMs, clip.outMs < Int64.max / 2,
              source.speed.isFinite, source.speed > 0 else { throw ClipRenderer.RenderError.invalidRange }
        let fps = source.fps ?? 0
        let canSnap = fps.isFinite && fps > 0 && fps < 1000
        let start = canSnap ? FrameMath.snapToFrame(ms: clip.inMs, fps: fps) : clip.inMs
        let end = canSnap ? FrameMath.snapToFrame(ms: clip.outMs, fps: fps) : clip.outMs
        self.inMs = max(0, start)
        self.outMs = source.durationMs.map { min(end, $0) } ?? end
        guard self.outMs > self.inMs else { throw ClipRenderer.RenderError.invalidRange }
        self.sourcePath = source.path
        self.rotation = source.rotation
        self.speed = source.speed
        self.preset = preset
        self.outputURL = outputURL
        let duration = expectedDurationSeconds
        guard duration.isFinite, duration > 0, duration * 1000 < Double(Int64.max) else {
            throw ClipRenderer.RenderError.invalidRange
        }
    }
}

struct ClipRenderResult: Sendable {
    let durationMs: Int64
    let bytes: Int64
}

/// Owns only a private sibling directory. Final publication is an exclusive
/// rename, so a destination created while rendering cannot be overwritten or
/// removed by this job's failure/cancellation cleanup.
struct StagedRenderOutput {
    let destination: URL
    let directory: URL
    let url: URL

    init(destination: URL) throws {
        self.destination = destination
        directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipx-render-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func publish() throws {
        let result = url.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

enum ClipRenderer {
    enum RenderError: LocalizedError {
        case invalidRange, emptyOutput, backendFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "The clip has an invalid time range or playback speed."
            case .emptyOutput: return "The renderer did not produce a playable video."
            case .backendFailed(let code): return "ffmpeg exited with code \(code)."
            }
        }
    }

    typealias Operation = (ClipRenderRequest, CancellerBox, @escaping @Sendable (Double) -> Void) async throws -> ClipRenderResult

    static func render(
        _ request: ClipRenderRequest,
        cancellation: CancellerBox = CancellerBox(),
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ClipRenderResult {
        defer { cancellation.set(nil) }
        return try await withTaskCancellationHandler {
            try cancellation.checkCancellation()
            let output = try StagedRenderOutput(destination: request.outputURL)
            defer { output.cleanup() }
            #if DIRECT_BUILD
            var sourcePath = request.sourcePath
            var inMs = request.inMs, outMs = request.outMs
            var rotation = request.rotation, speed = request.speed
            let convertsColor = try await requiresSDRConversion(sourcePath: sourcePath)
            if convertsColor {
                // Use the native color compositor for conversion to Rec.709.
                // A ProRes intermediate retains precision for ffmpeg's final
                // encode and loudness normalization, without a zimg dependency.
                let url = output.directory.appendingPathComponent("sdr-\(UUID().uuidString).mov")
                try await AVFoundationBackend.export(
                    sourcePath: sourcePath, inMs: inMs, outMs: outMs, preset: request.preset,
                    outputPath: url.path, rotation: rotation, speed: speed, useProResIntermediate: true,
                    onCancellerRegistered: { cancellation.set($0) }, onProgress: { onProgress($0 * 0.5) }
                )
                try cancellation.checkCancellation()
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard duration.isFinite, duration > 0, duration * 1000 < Double(Int64.max) else { throw RenderError.emptyOutput }
                sourcePath = url.path
                inMs = 0; outMs = Int64((duration * 1000).rounded())
                rotation = 0; speed = 1
            }
            let args = FFmpegBackend.buildArguments(
                sourcePath: sourcePath, inMs: inMs, outMs: outMs,
                preset: request.preset, outputPath: output.url.path,
                rotation: rotation, speed: speed
            )
            let status = try await FFmpegBackend.run(
                arguments: args, durationSec: request.expectedDurationSeconds,
                onCancellerRegistered: { cancellation.set($0) },
                onProgress: { onProgress(convertsColor ? 0.5 + $0 * 0.5 : $0) }
            )
            try cancellation.checkCancellation()
            guard status == 0 else { throw RenderError.backendFailed(status) }
            #else
            try await AVFoundationBackend.export(
                sourcePath: request.sourcePath, inMs: request.inMs, outMs: request.outMs,
                preset: request.preset, outputPath: output.url.path,
                rotation: request.rotation, speed: request.speed,
                onCancellerRegistered: { cancellation.set($0) }, onProgress: onProgress
            )
            #endif
            try cancellation.checkCancellation()
            let asset = AVURLAsset(url: output.url)
            let duration = try await asset.load(.duration).seconds
            let bytes = (try FileManager.default.attributesOfItem(atPath: output.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard duration.isFinite, duration > 0, duration * 1000 < Double(Int64.max), bytes > 0 else {
                throw RenderError.emptyOutput
            }
            try cancellation.checkCancellation()
            try output.publish()
            onProgress(1)
            return ClipRenderResult(durationMs: Int64((duration * 1000).rounded()), bytes: bytes)
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Reads the current file's metadata so old database rows do not bypass
    /// conversion. Untagged video keeps the existing SDR interpretation.
    static func requiresSDRConversion(sourcePath: String) async throws -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.emptyOutput }
        for description in try await track.load(.formatDescriptions) {
            let primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            let matrix = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
            if (primaries != nil && primaries != AVVideoColorPrimaries_ITU_R_709_2) ||
                (transfer != nil && transfer != AVVideoTransferFunction_ITU_R_709_2) ||
                (matrix != nil && matrix != AVVideoYCbCrMatrix_ITU_R_709_2) { return true }
        }
        return false
    }
}
