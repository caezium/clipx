import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Clipx is a dark-first app. Lock AppKit to dark so the Settings window,
        // About box, and open/save panels all match the dark SwiftUI UI instead
        // of rendering light against it.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Under XCTest, skip every side-effect of launch — bootstrap, sleep/
        // wake observers, hotkey registration, Sparkle. Tests use
        // Database.inMemory() and the host app exists only to satisfy the
        // BUNDLE_LOADER linkage; doing real work here makes the test runner
        // time out waiting for connection.
        guard !Self.isRunningUnderXCTest else { return }

        AppEnvironment.shared.bootstrap()

        // Pause player + suspend watchers on system sleep; resume on wake.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        #if DIRECT_BUILD
        GlobalHotkey.shared.register()
        UpdateManager.shared.start()
        #endif
    }

    /// True when the host app was launched by `xcodebuild test` rather than
    /// by a user. Checks multiple signals because individual ones can be
    /// absent depending on the test driver version.
    private static var isRunningUnderXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCInjectBundle"] != nil
            || env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    @objc private func handleWillSleep() {
        ClipxLog.app.info("system will sleep — pausing watchers")
        Task { @MainActor in
            AppEnvironment.shared.watcher?.stopAll()
            NotificationCenter.default.post(name: .systemWillSleep, object: nil)
        }
    }

    @objc private func handleDidWake() {
        ClipxLog.app.info("system did wake — resuming watchers")
        Task { @MainActor in
            AppEnvironment.shared.watcher?.resumeAll()
            NotificationCenter.default.post(name: .systemDidWake, object: nil)
        }
    }

    /// Block quit if exports are in flight; ask the user.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let jobsInFlight = AppEnvironment.shared.exportPipeline?.activeJobCount ?? 0
        guard jobsInFlight > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "\(jobsInFlight) export\(jobsInFlight == 1 ? "" : "s") still running"
        alert.informativeText = "Quitting now will cancel the remaining jobs and leave partial files on disk."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.shutdown()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let systemWillSleep = Notification.Name("clipx.system.willSleep")
    static let systemDidWake   = Notification.Name("clipx.system.didWake")
}
