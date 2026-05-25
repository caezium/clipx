import Foundation

/// Generates a minimal FCPXML 1.13 document referencing the chosen clips so
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
        var errorDescription: String? {
            switch self {
            case .missingMetadata(let path):
                return "Source \"\(path)\" is missing fps/width/height — re-index the folder or open the file in QuickTime once to populate metadata."
            case .noClips:
                return "No clips to export."
            }
        }
    }

    static func write(clipIDs: [Int64], to url: URL) throws {
        let xml = try buildDocument(clipIDs: clipIDs)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    static func buildDocument(clipIDs: [Int64]) throws -> String {
        guard !clipIDs.isEmpty else { throw FCPError.noClips }
        guard let database = AppEnvironment.shared.database else {
            throw NSError(domain: "clipx.fcpxml", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Library is not loaded yet."])
        }
        var formats: [(id: String, fps: Double, width: Int, height: Int)] = []
        var assetClips: [String] = []
        var spineClips: [String] = []
        var currentOffsetMs: Int64 = 0
        var formatCounter = 1
        var assetCounter = 1

        for clipID in clipIDs {
            guard let clip: Clip = try database.read({ db in
                try Clip.fetchOne(db, key: clipID)
            }) else { continue }
            guard let source: Source = try database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { continue }

            // Fail loudly rather than fabricate defaults.
            guard let fps = source.fps,
                  let width = source.width,
                  let height = source.height else {
                throw FCPError.missingMetadata(sourcePath: source.path)
            }

            // Find or create format
            let formatID: String
            if let existing = formats.first(where: { $0.fps == fps && $0.width == width && $0.height == height }) {
                formatID = existing.id
            } else {
                formatID = "r\(formatCounter)"
                formatCounter += 1
                formats.append((id: formatID, fps: fps, width: width, height: height))
            }

            let assetID = "a\(assetCounter)"
            assetCounter += 1
            let durationFrames = Int((Double(source.durationMs ?? 0) / 1000.0) * fps)
            let inFrames = Int((Double(clip.inMs) / 1000.0) * fps)
            let clipFrames = Int((Double(clip.durationMs) / 1000.0) * fps)

            // Build the file:// URL by percent-encoding the *raw* path —
            // previously the path was HTML-escaped first, so a filename
            // containing "&" became "%26amp%3B" and FCP couldn't resolve it.
            let percentEncoded = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path
            let assetURL = "file://" + percentEncoded

            assetClips.append("""
            <asset id="\(assetID)" name="\(escape(source.displayName))" src="\(escape(assetURL))" start="0s" duration="\(rationalSeconds(frames: durationFrames, fps: fps))" hasVideo="1" hasAudio="1" format="\(formatID)" videoSources="1" audioSources="1" audioChannels="2" audioRate="48000"/>
            """)

            let offsetFrames = Int((Double(currentOffsetMs) / 1000.0) * fps)
            spineClips.append("""
            <asset-clip name="\(escape(clip.name ?? source.displayName))" ref="\(assetID)" offset="\(rationalSeconds(frames: offsetFrames, fps: fps))" start="\(rationalSeconds(frames: inFrames, fps: fps))" duration="\(rationalSeconds(frames: clipFrames, fps: fps))" format="\(formatID)"/>
            """)
            currentOffsetMs += clip.durationMs
        }

        let formatXML = formats.map { fmt in
            "<format id=\"\(fmt.id)\" name=\"FFVideoFormat\(fmt.width)x\(fmt.height)p\(Int(fmt.fps.rounded()))\" frameDuration=\"\(frameDurationRational(fps: fmt.fps))\" width=\"\(fmt.width)\" height=\"\(fmt.height)\"/>"
        }.joined(separator: "\n            ")

        let primaryFormatID = formats.first?.id ?? "r1"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.13">
            <resources>
                \(formatXML)
                \(assetClips.joined(separator: "\n            "))
            </resources>
            <library>
                <event name="Clipx Export">
                    <project name="Clipx Selection">
                        <sequence format="\(primaryFormatID)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
                                \(spineClips.joined(separator: "\n                            "))
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
        let n = frames * den
        let d = num
        return "\(n)/\(d)s"
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
            return (Int(fps.rounded()), 1)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}
