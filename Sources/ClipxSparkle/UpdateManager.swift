#if DIRECT_BUILD
import Foundation
import Sparkle

/// Wraps SPUStandardUpdaterController so menu items and Settings can call
/// `checkForUpdates()` and let Sparkle manage the rest.
final class UpdateManager: NSObject {
    static let shared = UpdateManager()
    private var updaterController: SPUStandardUpdaterController!

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        // Sparkle starts on init. This call exists so AppDelegate can express
        // intent at launch (no-op today; reserved for future logic).
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#endif
