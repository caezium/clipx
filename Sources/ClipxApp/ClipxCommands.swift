import SwiftUI

/// Menu commands and keyboard shortcuts wired at the App scene level.
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
        }
        CommandMenu("Clip") {
            Button("Mark In") { MarkerActions.markIn() }.keyboardShortcut("i", modifiers: [])
            Button("Mark Out") { MarkerActions.markOut() }.keyboardShortcut("o", modifiers: [])
            Button("Save Range as Clip") { MarkerActions.saveRange() }.keyboardShortcut("s", modifiers: [])
            Divider()
            Button("Previous Frame") { PlayerActions.stepBackward() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Frame") { PlayerActions.stepForward() }.keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button("Rate ★★★★★") { MarkerActions.rate(5) }.keyboardShortcut("5", modifiers: [])
            Button("Rate ★★★★") { MarkerActions.rate(4) }.keyboardShortcut("4", modifiers: [])
            Button("Rate ★★★") { MarkerActions.rate(3) }.keyboardShortcut("3", modifiers: [])
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
                .applicationName: "Clipx",
                .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                .credits: NSAttributedString(string: "The fastest way to mark, find, and export clips.")
            ]
        )
    }
}

extension Notification.Name {
    static let focusSearchField = Notification.Name("clipx.focusSearchField")
    static let playerDidLoadSource = Notification.Name("clipx.playerDidLoadSource")
    static let markerDidChange = Notification.Name("clipx.markerDidChange")
}
