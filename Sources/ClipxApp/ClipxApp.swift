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
        // No title text in the toolbar — the sidebar wordmark is the brand, so
        // a duplicate "Clipx" label just crowds the top bar. (showsTitle: false)
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
