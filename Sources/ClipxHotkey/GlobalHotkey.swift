#if DIRECT_BUILD
import Foundation
import Carbon
import AppKit

/// Global Cmd+Shift+C — quick-add the frontmost video file to the library.
/// Carbon-based because NSEvent's local monitor doesn't work app-wide.
/// MAS build sandbox blocks Carbon hotkey APIs entirely — this file is
/// excluded from that target.
///
/// `register()` is idempotent (unregisters first if already bound) and checks
/// every Carbon status code. AppDelegate is responsible for calling
/// `unregister()` on willTerminate.
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {
        // Auto-unregister on app quit so we don't leak the Carbon refs.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    @objc private func handleTerminate() {
        unregister()
    }

    func register() {
        // Idempotent — drop any previous registration before re-binding.
        // Previously, a double-call leaked both `hotKeyRef` and `handlerRef`.
        unregister()

        let signature: OSType = OSType(0x434C5058) // 'CLPX'
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        // Cmd+Shift+C = kVK_ANSI_C with cmdKey + shiftKey
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_C)

        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            ClipxLog.app.error("GlobalHotkey.register failed: \(registerStatus)")
            return
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                { (_, _, _) -> OSStatus in
                                                    GlobalHotkey.shared.handleHotkey()
                                                    return noErr
                                                },
                                                1, &eventSpec, nil, &handlerRef)
        if handlerStatus != noErr {
            ClipxLog.app.error("GlobalHotkey: InstallEventHandler failed: \(handlerStatus)")
            // Roll back the registered hotkey so we don't leak it.
            if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    private func handleHotkey() {
        // Pull the frontmost file URL from the frontmost app's selection.
        Task { @MainActor in
            let script = """
            tell application "System Events"
                set frontApp to name of first process whose frontmost is true
            end tell
            if frontApp is "QuickTime Player" then
                tell application "QuickTime Player"
                    try
                        return POSIX path of (file of front document as alias)
                    on error
                        return ""
                    end try
                end tell
            else if frontApp is "Finder" then
                tell application "Finder"
                    set sel to selection
                    if (count of sel) > 0 then
                        return POSIX path of (item 1 of sel as alias)
                    end if
                    return ""
                end tell
            end if
            return ""
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script),
               let result = appleScript.executeAndReturnError(&error).stringValue,
               !result.isEmpty {
                guard let indexer = AppEnvironment.shared.indexer else {
                    AppState.shared.showToast("Library still loading — try again", level: .warning)
                    return
                }
                let url = URL(fileURLWithPath: result)
                // Index off the main actor so the hotkey doesn't stall UI.
                Task.detached { await indexer.indexFile(url) }
                AppState.shared.showToast(
                    "Added \(url.lastPathComponent) via quick-add",
                    level: .success
                )
            } else {
                AppState.shared.showToast(
                    "No frontmost video found",
                    level: .warning
                )
            }
        }
    }
}
#endif
