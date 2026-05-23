import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app shows in the dock and behaves as a regular GUI app
        NSApp.setActivationPolicy(.regular)

        // Bootstrap the app environment (DB, watchers, etc.)
        AppEnvironment.shared.bootstrap()

        // Direct-build only: register global hotkey and Sparkle updater
        #if DIRECT_BUILD
        GlobalHotkey.shared.register()
        UpdateManager.shared.start()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
