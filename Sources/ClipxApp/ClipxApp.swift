import SwiftUI

@main
struct ClipxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup("Clipx") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1280, idealWidth: 1320, minHeight: 700, idealHeight: 820)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
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
