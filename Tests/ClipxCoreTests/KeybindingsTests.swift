import XCTest
@testable import Clipx

/// Verifies the "menu shortcut hijack" fix at the source level: the
/// `ClipxCommands` file must not bind plain unmodified letter/digit keys as
/// global menu shortcuts. Doing so used to swallow keystrokes inside focused
/// TextFields and silently move markers.
///
/// We assert against the source text because there's no runtime API to ask
/// "what are this Commands struct's shortcuts?". Brittle on refactor, but the
/// alternative is a UI test that requires a real app session.
final class KeybindingsTests: XCTestCase {
    func test_clipxCommands_doesNotBindPlainLetterShortcuts() throws {
        let source = try loadClipxCommandsSource()
        // Catches `keyboardShortcut("i", modifiers: [])` and any other plain
        // single-letter bindings. The closing bracket is intentional —
        // `modifiers: [.command]` etc. is fine.
        let forbidden = #"keyboardShortcut("(?:[a-zA-Z0-9])", modifiers: \[\])"#
        let regex = try NSRegularExpression(pattern: forbidden)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(matches.count, 0, "ClipxCommands has plain-modifier shortcuts that hijack TextFields: \(matches.count) match(es)")
    }

    func test_clipxCommands_doesNotBindPlainArrowShortcuts() throws {
        let source = try loadClipxCommandsSource()
        XCTAssertFalse(source.contains("keyboardShortcut(.leftArrow, modifiers: [])"))
        XCTAssertFalse(source.contains("keyboardShortcut(.rightArrow, modifiers: [])"))
    }

    func test_playerView_saveButton_hasNoPlainShortcut() throws {
        let source = try loadSource(named: "PlayerView.swift", in: "ClipxPlayer")
        // The Save button used to carry `.keyboardShortcut("s", modifiers: [])`
        // which is the same hijack class.
        XCTAssertFalse(
            source.contains(#".keyboardShortcut("s", modifiers: [])"#),
            "PlayerView.Save button must not bind plain S — use onKeyPress instead"
        )
    }

    private func loadClipxCommandsSource() throws -> String {
        try loadSource(named: "ClipxCommands.swift", in: "ClipxApp")
    }

    /// Reads a source file from the project tree. Walks up from the test
    /// bundle until it finds the `Sources` directory — works regardless of
    /// where xcodebuild puts derived data.
    private func loadSource(named filename: String, in module: String) throws -> String {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(module, isDirectory: true)
                .appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "KeybindingsTests", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't locate \(filename) under Sources/\(module) walking up from \(#file)"]
        )
    }
}
