import SwiftUI

@main
struct ClipxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Tests rely on the host app launching without hanging; macOS's
        // single-Window Scene was making the test runner time out waiting
        // for connection. WindowGroup behaves like a normal app under
        // XCTest. The multi-window risk is real (see issue note) but lives
        // for a follow-up.
        WindowGroup("Clipx") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 900, idealWidth: 1320, minHeight: 700, idealHeight: 820)
        }
        .windowStyle(.titleBar)
        // No title text — the app's controls live in the unified toolbar (see
        // LibraryView/PlayerWorkspace .toolbar), so the title-bar row is filled
        // with search + controls next to the traffic lights, not an empty strip.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 820)
        .commands {
            ClipxCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
