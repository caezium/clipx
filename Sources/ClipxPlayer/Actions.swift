import Foundation

/// Static action handlers wired to menu items and global hotkeys. Bridges the
/// menu/keyboard layer to the `PlayerController` / `MarkerStore` instances.
enum MarkerActions {
    static func markIn() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .markIn, object: nil)
        }
    }
    static func markOut() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .markOut, object: nil)
        }
    }
    static func saveRange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .saveRange, object: nil)
        }
    }
    static func rate(_ value: Int) {
        Task { @MainActor in
            guard let markerStore = AppEnvironment.shared.markerStore else {
                AppState.shared.showToast("Library still loading — try again in a moment", level: .warning)
                return
            }
            let ids = AppState.shared.selectedClipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("Select a clip first to rate", level: .info)
                return
            }
            for id in ids {
                try? markerStore.updateRating(id, rating: value)
            }
            AppState.shared.showToast("Rated \(ids.count) clip(s) ★\(value)", level: .success)
        }
    }
}

enum PlayerActions {
    static func stepBackward() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .playerStepBack, object: nil)
        }
    }
    static func stepForward() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .playerStepForward, object: nil)
        }
    }
}

/// Centralized notification names. Defined here (NOT in ClipxCommands) so
/// every poster + observer references the same source-of-truth — avoids typo
/// bugs from declaring `.markIn` in two files.
extension Notification.Name {
    static let markIn               = Notification.Name("clipx.markIn")
    static let markOut              = Notification.Name("clipx.markOut")
    static let saveRange            = Notification.Name("clipx.saveRange")
    static let playerStepBack       = Notification.Name("clipx.player.stepBack")
    static let playerStepForward    = Notification.Name("clipx.player.stepForward")
    static let focusSearchField     = Notification.Name("clipx.focusSearchField")
    static let markerDidChange      = Notification.Name("clipx.markerDidChange")
}
