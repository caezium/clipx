#if DIRECT_BUILD
import Foundation

/// Direct-build export backend. Shells out to a bundled ffmpeg binary.
final class FFmpegBackend {
    /// Path to the bundled ffmpeg executable. In the shipped app this lives at
    /// `Contents/Helpers/ffmpeg`. During dev the build script symlinks the
    /// Homebrew binary so unsigned dev builds work.
    static var ffmpegPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
           FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        #if DEBUG
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        #endif
        return bundled
    }

    /// Decompose a speed multiplier into a chain of `atempo` filters, since each
    /// atempo only accepts 0.5…2.0. e.g. 4.0 → ["atempo=2.0","atempo=2.0"].
    static func atempoChain(_ speed: Double) -> [String] {
        guard speed.isFinite, speed > 0, speed != 1.0 else { return [] }
        var remaining = speed
        var parts: [String] = []
        while remaining > 2.0 { parts.append("atempo=2.0"); remaining /= 2.0 }
        while remaining < 0.5 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append("atempo=\(String(format: "%.4f", remaining))")
        return parts
    }

    static func buildArguments(
        sourcePath: String,
        inMs: Int64,
        outMs: Int64,
        preset: ExportPreset,
        outputPath: String,
        rotation: Int = 0,
        speed: Double = 1.0
    ) -> [String] {
        let durationSec = max(0, (Double(outMs) - Double(inMs)) / 1000.0)
        let startSec = Double(inMs) / 1000.0
        let rate = speed.isFinite && speed > 0 ? speed : 1
        let duration = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), durationSec)
        // With transcoding, input -ss uses accurate seek by default: decode
        // from the preceding keyframe and discard frames before In. Both
        // streams are trimmed in SOURCE time and reset to zero before retiming.
        // An output -ss/-t would instead cut the already-retimed timeline.
        var args: [String] = [
            "-nostdin", "-y",
            "-ss", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, startSec)),
            "-t", duration,
            "-i", sourcePath,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", ["trim=duration=\(duration)",
                    "setpts=(PTS-STARTPTS)/\(rate)",
                    VideoRotation.ffmpegFilter(degrees: rotation),
                    FramingPolicy.ffmpegFilter(width: preset.width, height: preset.height),
                    "fps=\(preset.frameRate)",
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"]
                .compactMap { $0 }.joined(separator: ","),
            "-r", String(preset.frameRate),
            "-c:v", ChipDetector.recommendedH264Codec(),
            "-b:v", "\(preset.videoBitrateKbps)k",
            "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709",
            "-color_trc", "bt709",
            "-colorspace", "bt709",
        ]
        // Audio filter chain: speed (atempo) first, then loudness if targeted.
        var audioFilters = ["atrim=duration=\(duration)", "asetpts=PTS-STARTPTS"] + atempoChain(rate)
        if let lufs = preset.lufsTarget {
            audioFilters.append("loudnorm=I=\(lufs):TP=-1.5:LRA=7")
        }
        let renderedDuration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), durationSec / rate)
        audioFilters += ["apad=whole_dur=\(renderedDuration)", "atrim=duration=\(renderedDuration)"]
        if !audioFilters.isEmpty {
            args.append(contentsOf: ["-af", audioFilters.joined(separator: ",")])
        }
        args.append(contentsOf: [
            "-c:a", "aac",
            "-b:a", "\(preset.audioBitrateKbps)k",
            "-movflags", "+faststart",
            "-progress", "pipe:2",       // machine-readable progress on stderr (#13)
            outputPath
        ])
        return args
    }

    static func run(
        arguments: [String],
        durationSec: Double = 0,
        onCancellerRegistered: ((@Sendable @escaping () -> Void) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let path = ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
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
            // Drain stderr to keep ffmpeg from blocking on a full pipe, and
            // parse `-progress pipe:2` output into a 0...1 fraction. (#13)
            let data = fh.availableData
            guard !data.isEmpty else { return }
            if let onProgress, durationSec > 0,
               let chunk = String(data: data, encoding: .utf8),
               let us = FFmpegProgress.latestOutTimeUs(chunk) {
                onProgress(FFmpegProgress.fraction(outTimeUs: us, durationSec: durationSec))
            }
        }

        let control = ProcessControl(process: process)
        onCancellerRegistered? { control.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { proc in
                    handle.readabilityHandler = nil
                    if control.isCancelled { cont.resume(throwing: CancellationError()) }
                    else { cont.resume(returning: proc.terminationStatus) }
                }
                do {
                    try control.start()
                } catch {
                    handle.readabilityHandler = nil
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Serializes launch with cancellation so cancelling before process.run()
    /// cannot be lost or call terminate() on an unlaunched process.
    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var cancelled = false

        init(process: Process) { self.process = process }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func start() throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}
#endif
