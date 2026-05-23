#if DIRECT_BUILD
import Foundation
import Carbon
import AppKit

/// Global Cmd+Shift+C — quick-add the frontmost video file to the library.
/// Carbon-based because NSEvent's local monitor doesn't work app-wide.
/// MAS build sandbox blocks Carbon hotkey APIs entirely — this file is
/// excluded from that target.
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        let signature: OSType = OSType(0x434C5058) // 'CLPX'
        var hotKeyID = EventHotKeyID(signature: signature, id: 1)

        // Cmd+Shift+C = key code 8 with cmdKey + shiftKey
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 8 // C

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            NSLog("GlobalHotkey.register failed: \(status)")
            return
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                             { (_, eventRef, _) -> OSStatus in
                                 GlobalHotkey.shared.handleHotkey()
                                 return noErr
                             },
                             1, &eventSpec, nil, &handlerRef)
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef = handlerRef {
            RemoveEventHandler(handlerRef)
        }
        hotKeyRef = nil
        handlerRef = nil
    }

    private func handleHotkey() {
        // Pull the frontmost file URL from the frontmost app's selection.
        // For QuickTime / Finder we can use AppleScript via NSAppleScript.
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
                let url = URL(fileURLWithPath: result)
                await AppEnvironment.shared.indexer.indexFile(url)
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
