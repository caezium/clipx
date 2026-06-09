import SwiftUI

/// Menu commands wired at the App scene level.
///
/// **Keyboard shortcut policy**: plain unmodified keys (I, O, S, 3-5, arrows)
/// are NOT bound here. Menu shortcuts win over focused TextFields, so binding
/// "o" to Mark Out at the menu level means typing "o" in the search box
/// silently moves the out-point. Player-local hotkeys live in `PlayerView`
/// via `onKeyPress`, which only fires when the player has focus.
struct ClipxCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Clipx") { showAboutPanel() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Import Folder…") {
                Task { @MainActor in
                    await ImportCoordinator.shared.pickFolder()
                }
            }
            .keyboardShortcut("o", modifiers: [.command])
            Button("Rescan Library Folders") {
                AppEnvironment.shared.watcher?.rescanAll()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        // Clip menu items remain clickable for discoverability; the keyboard
        // path goes through PlayerView's local onKeyPress so TextFields are
        // safe.
        CommandMenu("Clip") {
            Button("Mark In") { MarkerActions.markIn() }
            Button("Mark Out") { MarkerActions.markOut() }
            Button("Save Range as Clip") { MarkerActions.saveRange() }
            Divider()
            Button("Previous Frame") { PlayerActions.stepBackward() }
            Button("Next Frame") { PlayerActions.stepForward() }
            Divider()
            Button("Rate ★★★★★") { MarkerActions.rate(5) }
            Button("Rate ★★★★") { MarkerActions.rate(4) }
            Button("Rate ★★★") { MarkerActions.rate(3) }
        }
        CommandMenu("Find") {
            Button("Command Palette…") {
                appState.commandPaletteOpen.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command])
            Button("Search Clips") {
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        CommandGroup(after: .help) {
            // Cmd+? (Cmd+Shift+/ on US layouts) — standard Mac help shortcut.
            Button("Keyboard Shortcuts") {
                appState.shortcutOverlayOpen.toggle()
            }
            .keyboardShortcut("?", modifiers: [.command])
            Button("Export Progress…") {
                appState.exportProgressOpen.toggle()
            }
        }
        CommandMenu("Export") {
            Button("Reels (9:16 1080p)") { ExportActions.exportSelected(.reels) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("YouTube 1080p") { ExportActions.exportSelected(.youtube1080p) }
            Button("YouTube 4K") { ExportActions.exportSelected(.youtube4k) }
            Button("Instagram Feed (4:5)") { ExportActions.exportSelected(.instagramFeed) }
            Divider()
            Button("FCPXML (Final Cut Pro)…") { ExportActions.exportFCPXML() }
            Button("Obsidian Sidecars…") { ExportActions.exportObsidian() }
        }
    }

    private func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(
            options: [
                .credits: NSAttributedString(string: "The fastest way to mark, find, and export clips.")
            ]
        )
    }
}
