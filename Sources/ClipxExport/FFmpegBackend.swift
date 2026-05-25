#if DIRECT_BUILD
import Foundation

/// Direct-build export backend. Shells out to a bundled ffmpeg binary.
///
/// `run` now uses `terminationHandler` + a continuation instead of blocking
/// `waitUntilExit()` on the cooperative pool. The pipeline registers a
/// canceller closure that calls `process.terminate()` so `cancelAll()`
/// actually interrupts an ffmpeg in flight.
final class FFmpegBackend {
    /// Path to the bundled ffmpeg executable. In the shipped app this lives at
    /// `Contents/Helpers/ffmpeg`. During dev the build script symlinks the
    /// Homebrew binary so unsigned dev builds work.
    static var ffmpegPath: String {
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
           FileManager.default.fileExists(atPath: helper) {
            return helper
        }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffmpeg"
    }

    static func buildArguments(
        sourcePath: String,
        inMs: Int64,
        outMs: Int64,
        preset: ExportPreset,
        outputPath: String
    ) -> [String] {
        let durationSec = Double(outMs - inMs) / 1000.0
        let startSec = Double(inMs) / 1000.0
        // `-ss` BEFORE `-i` is keyframe-snapped (fast but inaccurate). Adding
        // a second `-ss 0` AFTER `-i` forces precise-seek to start exactly at
        // the user-marked in-point. ~10x slower decode of pre-keyframe-frames
        // but matches what the user actually marked.
        var args: [String] = [
            "-y",
            "-ss", String(format: "%.3f", max(0, startSec - 1)),
            "-i", sourcePath,
            "-ss", String(format: "%.3f", min(1, startSec)),
            "-t", String(format: "%.3f", durationSec),
            "-vf", "scale=\(preset.width):\(preset.height):force_original_aspect_ratio=decrease,pad=\(preset.width):\(preset.height):(ow-iw)/2:(oh-ih)/2:black",
            "-r", String(preset.frameRate),
            "-c:v", ChipDetector.recommendedH264Codec(),
            "-b:v", "\(preset.videoBitrateKbps)k",
            "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709",
            "-color_trc", "bt709",
            "-colorspace", "bt709",
        ]
        if let lufs = preset.lufsTarget {
            args.append(contentsOf: [
                "-af", "loudnorm=I=\(lufs):TP=-1.5:LRA=7"
            ])
        }
        args.append(contentsOf: [
            "-c:a", "aac",
            "-b:a", "\(preset.audioBitrateKbps)k",
            "-movflags", "+faststart",
            outputPath
        ])
        return args
    }

    static func run(
        arguments: [String],
        onCancellerRegistered: ((@Sendable @escaping () -> Void) -> Void)? = nil
    ) async throws -> Int32 {
        // Up-front existence check so the user gets a clear error instead of
        // a cryptic NSPOSIXErrorDomain when ffmpeg isn't bundled.
        let path = ffmpegPath
        guard FileManager.default.fileExists(atPath: path) || path == "ffmpeg" else {
            throw NSError(
                domain: "clipx.export",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg binary not found at \(path)"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            // Drain stderr to keep ffmpeg from blocking on a full pipe. We
            // don't parse progress; callers that want per-job progress
            // should switch to `-progress pipe:2` parsing.
            _ = fh.availableData
        }

        // Register canceller — pipeline calls this from cancelAll().
        onCancellerRegistered? { [weak process] in
            process?.terminate()
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}
#endif
