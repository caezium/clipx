import Foundation

/// Personal edits keep their text while a concurrently refreshed generated
/// review block keeps the server's latest value, including its removal.
enum ReviewNotesMerge {
    private static let start = "<!-- clipx:review -->"
    private static let end = "<!-- /clipx:review -->"

    static func merge(draft: String, baseline: String, current: String) -> String? {
        let currentBlock = block(in: current)
        guard currentBlock != block(in: baseline) else { return draft.isEmpty ? nil : draft }
        var merged = draft
        if let range = range(in: merged) {
            merged.replaceSubrange(range, with: currentBlock ?? "")
        } else if let currentBlock {
            merged += (merged.isEmpty ? "" : "\n\n") + currentBlock
        }
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private static func block(in text: String) -> String? {
        range(in: text).map { String(text[$0]) }
    }

    private static func range(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: start),
              let finish = text.range(of: end, range: begin.upperBound..<text.endIndex) else { return nil }
        return begin.lowerBound..<finish.upperBound
    }
}
