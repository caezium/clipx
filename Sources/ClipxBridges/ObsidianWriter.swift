import Foundation

/// Writes one `.md` sidecar per clip into a designated Obsidian vault folder.
/// Each sidecar contains YAML frontmatter (file path, in/out TC, tags, rating,
/// mood, shot type, project links) and a body section for human notes.
enum ObsidianWriter {
    /// Writes sidecar files for the given clip IDs. Returns the count written.
    @discardableResult
    static func writeSidecars(clipIDs: [Int64], vaultPath: String) throws -> Int {
        let folderURL = URL(fileURLWithPath: vaultPath, isDirectory: true)
        let clipsFolder = folderURL.appendingPathComponent("Clipx", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)

        var written = 0
        for clipID in clipIDs {
            guard let clip: Clip = try AppEnvironment.shared.database.read({ db in
                try Clip.fetchOne(db, key: clipID)
            }) else { continue }
            guard let source: Source = try AppEnvironment.shared.database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { continue }
            let tags = (try? AppEnvironment.shared.tagStore.tags(forClip: clipID).map(\.name)) ?? []

            let filename = sanitize(clip.name ?? "clip-\(clipID)") + ".md"
            let url = clipsFolder.appendingPathComponent(filename)
            let body = render(clip: clip, source: source, tags: tags)
            try body.write(to: url, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }

    private static func render(clip: Clip, source: Source, tags: [String]) -> String {
        var lines: [String] = ["---"]
        lines.append("clip_id: \(clip.id ?? 0)")
        lines.append("source: \"\(escape(source.path))\"")
        lines.append("source_name: \"\(escape(source.displayName))\"")
        lines.append("in_ms: \(clip.inMs)")
        lines.append("out_ms: \(clip.outMs)")
        lines.append("duration_sec: \(String(format: "%.3f", Double(clip.durationMs) / 1000.0))")
        lines.append("in_tc: \"\(formatTimecode(clip.inMs))\"")
        lines.append("out_tc: \"\(formatTimecode(clip.outMs))\"")
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
        lines.append("## Notes")
        lines.append("")
        if let notes = clip.notes, !notes.isEmpty {
            lines.append(notes)
        } else {
            lines.append("_Add notes here._")
        }
        lines.append("")
        lines.append("## Linked")
        lines.append("- Source: `\(source.path)`")
        return lines.joined(separator: "\n")
    }

    static func formatTimecode(_ ms: Int64) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec / 60) % 60
        let s = totalSec % 60
        let f = (ms % 1000) / 1000 * 30 // approximate; depends on source fps
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func sanitize(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: disallowed).joined(separator: "-")
    }
}
