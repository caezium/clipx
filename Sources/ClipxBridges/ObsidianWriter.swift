import Foundation

/// Writes one `.md` sidecar per clip into a designated Obsidian vault folder.
/// Each sidecar contains YAML frontmatter (file path, in/out TC, tags, rating,
/// mood, shot type, project links) and a body section for human notes.
/// Filenames use stable clip IDs. Existing frontmatter must match that ID
/// before any user-authored body is carried into a refreshed sidecar.
enum ObsidianWriter {
    @discardableResult
    static func writeSidecars(clipIDs: [Int64], vaultPath: String, database suppliedDatabase: Database? = nil) throws -> Int {
        guard let database = suppliedDatabase ?? AppEnvironment.shared.database else {
            throw NSError(domain: "clipx.obsidian", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Library is not loaded yet."])
        }
        let folderURL = URL(fileURLWithPath: vaultPath, isDirectory: true).standardizedFileURL
        let clipsFolder = folderURL.appendingPathComponent("Clipx", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        let existingFiles = try FileManager.default.contentsOfDirectory(at: clipsFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var written = 0
        for clipID in clipIDs {
            guard let clip = try database.read({ try Clip.fetchOne($0, key: clipID) }),
                  let source = try database.read({ try Source.fetchOne($0, key: clip.sourceID) }) else { continue }
            let tags: [String] = try database.read { db in
                try String.fetchAll(db, sql: "SELECT tags.name FROM tags JOIN clip_tags ON clip_tags.tag_id = tags.id WHERE clip_tags.clip_id = ? ORDER BY tags.name", arguments: [clipID])
            }
            // The display name can change or collide after sanitization. The
            // clip ID is the durable filename; metadata is checked before merge.
            let url = clipsFolder.appendingPathComponent("clip-\(clipID).md")
            var existingText: String?
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard documentClipID(text) == clipID else {
                    throw NSError(domain: "clipx.obsidian", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) belongs to another note; move it before exporting this clip."])
                }
                existingText = text
            } else {
                // Import notes from an old name-based sidecar only when its
                // frontmatter proves ownership. Leave the old file intact.
                for legacy in existingFiles {
                    guard let text = try? String(contentsOf: legacy, encoding: .utf8) else { continue }
                    if documentClipID(text) == clipID { existingText = text; break }
                }
            }
            let body = render(clip: clip, source: source, tags: tags,
                              existingBody: existingText.flatMap(readExistingUserBody))
            try body.write(to: url, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }

    static func documentClipID(_ text: String) -> Int64? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        for line in lines[1..<end] where line.hasPrefix("clip_id:") {
            return Int64(line.dropFirst("clip_id:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func readExistingUserBody(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var body = Array(lines.dropFirst(end + 1)).joined(separator: "\n")
        let startMarker = "<!-- clipx:links -->"
        let endMarker = "<!-- /clipx:links -->"
        if let start = body.range(of: startMarker),
           let end = body.range(of: endMarker, range: start.upperBound..<body.endIndex) {
            body.removeSubrange(start.lowerBound..<end.upperBound)
        } else {
            var bodyLines = body.components(separatedBy: "\n")
            if let linked = bodyLines.firstIndex(of: "## Linked"), linked + 1 < bodyLines.count,
               bodyLines[linked + 1].hasPrefix("- Source: `"), bodyLines[linked + 1].hasSuffix("`") {
                bodyLines.removeSubrange(linked...(linked + 1))
            }
            body = bodyLines.joined(separator: "\n")
        }
        let trimmed = body.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func render(clip: Clip, source: Source, tags: [String], existingBody: String?) -> String {
        var lines: [String] = ["---"]
        lines.append("clip_id: \(clip.id ?? 0)")
        lines.append("name: \"\(escape(clip.name ?? source.displayName))\"")
        lines.append("source: \"\(escape(source.path))\"")
        lines.append("source_name: \"\(escape(source.displayName))\"")
        lines.append("in_ms: \(clip.inMs)")
        lines.append("out_ms: \(clip.outMs)")
        lines.append("duration_sec: \(String(format: "%.3f", Double(clip.durationMs) / 1000.0))")
        let fps = source.fps ?? 30
        lines.append("in_tc: \"\(formatTimecode(clip.inMs, fps: fps))\"")
        lines.append("out_tc: \"\(formatTimecode(clip.outMs, fps: fps))\"")
        if let res = source.width, let h = source.height {
            lines.append("resolution: \"\(res)x\(h)\"")
        }
        if let fps = source.fps {
            lines.append("fps: \(String(format: "%.2f", fps))")
        }
        if let codec = source.codec { lines.append("codec: \"\(escape(codec))\"") }
        if clip.rating > 0 { lines.append("rating: \(clip.rating)") }
        if let mood = clip.mood, !mood.isEmpty {
            let arr = mood.split(separator: ",").map { "\"\(escape(String($0).trimmingCharacters(in: .whitespaces)))\"" }
            lines.append("mood: [\(arr.joined(separator: ", "))]")
        }
        if let shotType = clip.shotType { lines.append("shot_type: \"\(escape(shotType))\"") }
        if let move = clip.cameraMove { lines.append("camera_move: \"\(escape(move))\"") }
        if let setting = clip.setting { lines.append("setting: \"\(escape(setting))\"") }
        if !tags.isEmpty {
            let arr = tags.map { "\"\(escape($0))\"" }
            lines.append("tags: [\(arr.joined(separator: ", "))]")
        }
        lines.append("created_at: \(clip.createdAt)")
        lines.append("---")
        lines.append("")
        lines.append("<!-- clipx:links -->")
        lines.append("## Linked")
        lines.append("- Source: `\(source.path)`")
        lines.append("<!-- /clipx:links -->")
        lines.append("")
        if let existingBody {
            // Preserve all user sections, including text above ## Notes.
            lines.append(existingBody)
        } else {
            lines.append("## Notes")
            lines.append("")
            lines.append(clip.notes.flatMap { $0.isEmpty ? nil : $0 } ?? "_Add notes here._")
        }
        return lines.joined(separator: "\n")
    }

    /// Frames sub-field computed against the source's actual fps. Was
    /// previously `(ms % 1000) / 1000 * 30` — integer math, always 0.
    static func formatTimecode(_ ms: Int64, fps: Double = 30) -> String {
        let rate = fps.isFinite && fps > 0 && fps < 1000 ? fps : 30
        let frameCount = (Double(max(0, ms)) * rate / 1000).rounded()
        guard frameCount < Double(Int64.max) else { return "—" }
        let nominalFPS = Int64(rate.rounded())
        let totalFrames = Int64(frameCount)
        let totalSec = totalFrames / max(1, nominalFPS)
        return String(format: "%02lld:%02lld:%02lld:%02lld", totalSec / 3600,
                      (totalSec / 60) % 60, totalSec % 60, totalFrames % max(1, nominalFPS))
    }

    /// YAML scalar escape — handles double quotes, backslashes, and newlines
    /// so multi-line values don't break the document.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Strips path-separators, ".." segments, and other illegal characters.
    /// Defense in depth — the outer `clipsFolder.path` containment check is
    /// the real safety net.
    static func sanitize(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
        var cleaned = name.components(separatedBy: disallowed).joined(separator: "-")
        // Remove dot-segments outright — ".." and "." can navigate.
        cleaned = cleaned
            .replacingOccurrences(of: "..", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
