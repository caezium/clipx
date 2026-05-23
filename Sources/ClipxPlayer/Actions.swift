import Foundation

/// Static action handlers wired to menu items and global hotkeys. Bridges the
/// menu/keyboard layer to the `PlayerController` / `MarkerStore` instances.
enum MarkerActions {
    static func markIn() {
        // Posted so the active PlayerView picks it up via @EnvironmentObject.
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
            let ids = AppState.shared.selectedClipIDs
            for id in ids {
                try? AppEnvironment.shared.markerStore.updateRating(id, rating: value)
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

extension Notification.Name {
    static let markIn = Notification.Name("clipx.markIn")
    static let markOut = Notification.Name("clipx.markOut")
    static let saveRange = Notification.Name("clipx.saveRange")
    static let playerStepBack = Notification.Name("clipx.player.stepBack")
    static let playerStepForward = Notification.Name("clipx.player.stepForward")
}
