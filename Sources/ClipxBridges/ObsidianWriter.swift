import Foundation

/// Writes one `.md` sidecar per clip into a designated Obsidian vault folder.
/// Each sidecar contains YAML frontmatter (file path, in/out TC, tags, rating,
/// mood, shot type, project links) and a body section for human notes.
///
/// **Security**: `vaultPath` comes from UserDefaults, and clip names are
/// user-controlled, so the sanitizer strips `..` and the writer asserts the
/// resolved output URL is inside `clipsFolder`. Without those guards, a clip
/// named `../../etc/foo` could escape the vault.
///
/// **Merge**: previous version overwrote sidecars wholesale, destroying any
/// hand-written notes in the body. Now we preserve text below the
/// `## Notes` section if the file already exists.
enum ObsidianWriter {
    @discardableResult
    static func writeSidecars(clipIDs: [Int64], vaultPath: String) throws -> Int {
        guard let database = AppEnvironment.shared.database else {
            throw NSError(domain: "clipx.obsidian", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Library is not loaded yet."])
        }
        let folderURL = URL(fileURLWithPath: vaultPath, isDirectory: true).standardizedFileURL
        let clipsFolder = folderURL.appendingPathComponent("Clipx", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)

        var written = 0
        for clipID in clipIDs {
            guard let clip: Clip = try database.read({ db in
                try Clip.fetchOne(db, key: clipID)
            }) else { continue }
            guard let source: Source = try database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { continue }
            let tags = (try? AppEnvironment.shared.tagStore?.tags(forClip: clipID).map(\.name)) ?? []

            let filename = sanitize(clip.name ?? "clip-\(clipID)") + ".md"
            let url = clipsFolder.appendingPathComponent(filename).standardizedFileURL

            // Containment check — even after sanitize, asserting the resolved
            // path is inside clipsFolder is the belt-and-suspenders fix
            // against any future bypass.
            guard url.path.hasPrefix(clipsFolder.path + "/") else {
                throw NSError(
                    domain: "clipx.obsidian", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Resolved sidecar path \"\(url.path)\" escapes vault — refusing to write."]
                )
            }

            // Read existing user notes (everything under `## Notes`) so we
            // can re-attach them when overwriting frontmatter.
            let existingNotes = readExistingUserNotes(at: url)

            let body = render(clip: clip, source: source, tags: tags, existingNotes: existingNotes)
            try body.write(to: url, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }

    /// Returns the text after `## Notes` up to (but not including) the next
    /// `## Linked` section. Nil if the file doesn't exist or the section
    /// can't be located.
    private static func readExistingUserNotes(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let notesRange = text.range(of: "## Notes") else { return nil }
        var afterNotes = text[notesRange.upperBound...]
        // Drop the trailing newline immediately after the heading.
        if afterNotes.hasPrefix("\n") { afterNotes = afterNotes.dropFirst() }
        // Stop at next top-level section if present.
        let end: String.Index
        if let linkedRange = afterNotes.range(of: "\n## Linked") {
            end = linkedRange.lowerBound
        } else if let nextRange = afterNotes.range(of: "\n## ") {
            end = nextRange.lowerBound
        } else {
            end = afterNotes.endIndex
        }
        let body = String(afterNotes[afterNotes.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If existing body is the auto-placeholder, treat as "no user notes".
        if body.isEmpty || body == "_Add notes here._" { return nil }
        return body
    }

    private static func render(clip: Clip, source: Source, tags: [String], existingNotes: String?) -> String {
        var lines: [String] = ["---"]
        lines.append("clip_id: \(clip.id ?? 0)")
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
        lines.append("## Notes")
        lines.append("")
        // Preserve user-written notes across re-exports.
        if let existingNotes, !existingNotes.isEmpty {
            lines.append(existingNotes)
        } else if let notes = clip.notes, !notes.isEmpty {
            lines.append(notes)
        } else {
            lines.append("_Add notes here._")
        }
        lines.append("")
        lines.append("## Linked")
        lines.append("- Source: `\(source.path)`")
        return lines.joined(separator: "\n")
    }

    /// Frames sub-field computed against the source's actual fps. Was
    /// previously `(ms % 1000) / 1000 * 30` — integer math, always 0.
    static func formatTimecode(_ ms: Int64, fps: Double = 30) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec / 60) % 60
        let s = totalSec % 60
        let frames = Int64((Double(ms % 1000) * fps) / 1000.0)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
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
