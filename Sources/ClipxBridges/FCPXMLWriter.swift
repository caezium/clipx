import Foundation

/// Generates a minimal FCPXML 1.13 document referencing the chosen clips so
/// they drop straight onto a Final Cut Pro timeline with in/out preserved.
///
/// The format is intentionally narrow — we emit one `event` containing one
/// `project` with a single `sequence` whose `spine` lists the clips in order.
enum FCPXMLWriter {
    static func write(clipIDs: [Int64], to url: URL) throws {
        let xml = try buildDocument(clipIDs: clipIDs)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    static func buildDocument(clipIDs: [Int64]) throws -> String {
        var formats: [(id: String, fps: Double, width: Int, height: Int)] = []
        var assetClips: [String] = []
        var spineClips: [String] = []
        var currentOffsetMs: Int64 = 0
        var formatCounter = 1
        var assetCounter = 1

        for clipID in clipIDs {
            guard let clip: Clip = try AppEnvironment.shared.database.read({ db in
                try Clip.fetchOne(db, key: clipID)
            }) else { continue }
            guard let source: Source = try AppEnvironment.shared.database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { continue }

            let fps = source.fps ?? 30.0
            let width = source.width ?? 1920
            let height = source.height ?? 1080

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

            let escapedPath = source.path
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
            let assetURL = "file://" + escapedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!

            assetClips.append("""
            <asset id="\(assetID)" name="\(escape(source.displayName))" src="\(assetURL)" start="0s" duration="\(durationFrames)/\(Int(fps))s" hasVideo="1" hasAudio="1" format="\(formatID)" videoSources="1" audioSources="1" audioChannels="2" audioRate="48000"/>
            """)

            let offsetFrames = Int((Double(currentOffsetMs) / 1000.0) * fps)
            spineClips.append("""
            <asset-clip name="\(escape(clip.name ?? source.displayName))" ref="\(assetID)" offset="\(offsetFrames)/\(Int(fps))s" start="\(inFrames)/\(Int(fps))s" duration="\(clipFrames)/\(Int(fps))s" format="\(formatID)"/>
            """)
            currentOffsetMs += clip.durationMs
        }

        let formatXML = formats.map { fmt in
            "<format id=\"\(fmt.id)\" name=\"FFVideoFormat\(fmt.width)x\(fmt.height)p\(Int(fmt.fps))\" frameDuration=\"1/\(Int(fmt.fps))s\" width=\"\(fmt.width)\" height=\"\(fmt.height)\"/>"
        }.joined(separator: "\n            ")

        let primaryFormatID = formats.first?.id ?? "r1"
        let primaryFps = Int(formats.first?.fps ?? 30)

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

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
