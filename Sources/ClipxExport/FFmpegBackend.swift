#if DIRECT_BUILD
import Foundation

/// Direct-build export backend. Shells out to a bundled ffmpeg binary.
final class FFmpegBackend {
    /// Path to the bundled ffmpeg executable. In the shipped app this lives at
    /// `Contents/Helpers/ffmpeg`. During dev the build script symlinks the
    /// Homebrew binary so unsigned dev builds work.
    static var ffmpegPath: String {
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
           FileManager.default.fileExists(atPath: helper) {
            return helper
        }
        // Dev fallback — only available in Debug builds running from Xcode.
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
        var args: [String] = [
            "-y",
            "-ss", String(format: "%.3f", startSec),
            "-i", sourcePath,
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
        onProgress: @escaping (Double) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            // ffmpeg emits "frame=  234" lines; we don't always have total frames,
            // so we report indeterminate progress (-1) but emit ticks.
            if str.contains("frame=") { onProgress(-1) }
        }

        process.waitUntilExit()
        handle.readabilityHandler = nil
        return process.terminationStatus
    }
}
#endif
