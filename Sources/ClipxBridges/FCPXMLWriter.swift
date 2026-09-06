import Foundation

/// Generates a minimal FCPXML 1.10 document referencing the chosen clips so
/// they drop straight onto a Final Cut Pro timeline with in/out preserved.
///
/// The format is intentionally narrow — we emit one `event` containing one
/// `project` with a single `sequence` whose `spine` lists the clips in order.
enum FCPXMLWriter {
    /// Sources missing the metadata FCP needs (fps/width/height) used to be
    /// papered over with fake 1920×1080@30 defaults. That produced timelines
    /// that didn't match the source and FCP would render the wrong size /
    /// rate without warning. Now we throw so the user knows.
    enum FCPError: LocalizedError {
        case missingMetadata(sourcePath: String)
        case noClips
        case invalidRange
        var errorDescription: String? {
            switch self {
            case .missingMetadata(let path):
                return "Source \"\(path)\" is missing valid frame rate, dimensions, or duration. Restore the source file and rescan its folder."
            case .noClips:
                return "No clips to export."
            case .invalidRange:
                return "A clip cannot be represented as a valid frame range."
            }
        }
    }

    static func write(clipIDs: [Int64], to url: URL) throws {
        let xml = try buildDocument(clipIDs: clipIDs)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    static func buildDocument(clipIDs: [Int64], database suppliedDatabase: Database? = nil) throws -> String {
        guard !clipIDs.isEmpty else { throw FCPError.noClips }
        guard let database = suppliedDatabase ?? AppEnvironment.shared.database else {
            throw NSError(domain: "clipx.fcpxml", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Library is not loaded yet."])
        }
        let items: [(clip: Clip, source: Source)] = try database.read { db in
            try clipIDs.map { id in
                guard let clip = try Clip.fetchOne(db, key: id),
                      let source = try Source.fetchOne(db, key: clip.sourceID) else { throw FCPError.noClips }
                return (clip, source)
            }
        }
        return try buildDocument(items: items)
    }

    static func buildDocument(items: [(clip: Clip, source: Source)]) throws -> String {
        guard let first = items.first else { throw FCPError.noClips }
        var formats: [(id: String, fps: Double, width: Int, height: Int)] = []
        var assets: [String] = []
        var spine: [String] = []
        var sequenceOffsetFrames = 0
        guard let sequenceFPS = first.source.fps, sequenceFPS.isFinite, sequenceFPS > 0, sequenceFPS < 1000 else {
            throw FCPError.missingMetadata(sourcePath: first.source.path)
        }
        let sequenceRate = rationalForFps(sequenceFPS)
        let sequenceFramesPerSecond = Double(sequenceRate.0) / Double(sequenceRate.1)

        for (index, item) in items.enumerated() {
            let (clip, source) = item
            guard let fps = source.fps, fps.isFinite, fps > 0, fps < 1000,
                  let width = source.width, width > 0,
                  let height = source.height, height > 0,
                  let durationMs = source.durationMs, durationMs > 0, durationMs < 1_000_000_000_000,
                  clip.inMs >= 0, clip.outMs > clip.inMs, clip.outMs <= durationMs else {
                throw FCPError.missingMetadata(sourcePath: source.path)
            }
            let formatID: String
            if let existing = formats.first(where: { $0.fps == fps && $0.width == width && $0.height == height }) {
                formatID = existing.id
            } else {
                formatID = "r\(formats.count + 1)"
                formats.append((formatID, fps, width, height))
            }
            let assetID = "a\(index + 1)"
            let rate = rationalForFps(fps)
            let sourceFPS = Double(rate.0) / Double(rate.1)
            // Stored milliseconds are rounded frame boundaries. Recover each
            // endpoint independently so 0–33 ms at 30 fps remains one frame.
            let startFrame = Int((Double(clip.inMs) * sourceFPS / 1000).rounded())
            let endFrame = Int((Double(clip.outMs) * sourceFPS / 1000).rounded())
            guard endFrame > startFrame else { throw FCPError.invalidRange }
            let sourceDurationFrames = max(endFrame, Int((Double(durationMs) * sourceFPS / 1000).rounded()))
            let clipSeconds = Double(endFrame - startFrame) / sourceFPS
            let sequenceFrames = max(1, Int((clipSeconds * sequenceFramesPerSecond).rounded()))
            let assetURL = URL(fileURLWithPath: source.path).absoluteString
            let channels = source.audioChannels ?? 0
            let audioAttributes = channels > 0 ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(channels)\"" : " hasAudio=\"0\""
            assets.append("""
            <asset id="\(assetID)" name="\(escape(source.displayName))" start="0s" duration="\(rationalSeconds(frames: sourceDurationFrames, fps: fps))" hasVideo="1" format="\(formatID)" videoSources="1"\(audioAttributes)>
                <media-rep kind="original-media" src="\(escape(assetURL))"/>
            </asset>
            """)
            spine.append("""
            <asset-clip name="\(escape(clip.name ?? source.displayName))" ref="\(assetID)" offset="\(rationalSeconds(frames: sequenceOffsetFrames, fps: sequenceFPS))" start="\(rationalSeconds(frames: startFrame, fps: fps))" duration="\(rationalSeconds(frames: sequenceFrames, fps: sequenceFPS))" format="\(formatID)"/>
            """)
            let (nextOffset, overflow) = sequenceOffsetFrames.addingReportingOverflow(sequenceFrames)
            guard !overflow else { throw FCPError.invalidRange }
            sequenceOffsetFrames = nextOffset
        }
        let formatXML = formats.map { format in
            "<format id=\"\(format.id)\" frameDuration=\"\(frameDurationRational(fps: format.fps))\" width=\"\(format.width)\" height=\"\(format.height)\"/>"
        }.joined(separator: "\n            ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                \(formatXML)
                \(assets.joined(separator: "\n            "))
            </resources>
            <library>
                <event name="Clipx Export">
                    <project name="Clipx Selection">
                        <sequence format="r1" duration="\(rationalSeconds(frames: sequenceOffsetFrames, fps: sequenceFPS))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
                                \(spine.joined(separator: "\n                            "))
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
    }

    /// Produces an FCPXML rational time string for a number of frames at a
    /// given fps. For NTSC fractional rates (23.976, 29.97, 59.94) emits the
    /// canonical rational form so the resulting durations are bit-exact;
    /// integer rates emit `N/Rs`. Previously `Int(fps)` truncated 23.976→23
    /// and shifted every clip by ~0.1%.
    static func rationalSeconds(frames: Int, fps: Double) -> String {
        let (num, den) = rationalForFps(fps)
        // frames at fps `num/den` per second = frames * den / num seconds.
        let (n, overflow) = frames.multipliedReportingOverflow(by: den)
        guard !overflow else { return "0s" }
        return "\(n)/\(num)s"
    }

    static func frameDurationRational(fps: Double) -> String {
        // One frame = den/num seconds where fps = num/den.
        let (num, den) = rationalForFps(fps)
        return "\(den)/\(num)s"
    }

    /// Recognized NTSC rates first, then fall back to integer.
    private static func rationalForFps(_ fps: Double) -> (Int, Int) {
        // 1001/24000 etc. — den is the "timescale" axis in FCPXML.
        switch round(fps * 1000) / 1000 {
        case 23.976: return (24000, 1001)
        case 29.97:  return (30000, 1001)
        case 59.94:  return (60000, 1001)
        case 47.952: return (48000, 1001)
        default:
            guard fps.isFinite, fps > 0, fps < 1000 else { return (30, 1) }
            let numerator = Int((fps * 1_000_000).rounded())
            let divisor = gcd(numerator, 1_000_000)
            return (numerator / divisor, 1_000_000 / divisor)
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return max(1, a)
    }

    private static func escape(_ s: String) -> String {
        let legal = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        }))
        return legal.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}
