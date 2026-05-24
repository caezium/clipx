#if DIRECT_BUILD
import Foundation
import Sparkle

/// Wraps SPUStandardUpdaterController so menu items and Settings can call
/// `checkForUpdates()` and let Sparkle manage the rest.
final class UpdateManager: NSObject {
    static let shared = UpdateManager()
    private var updaterController: SPUStandardUpdaterController?

    private override init() {
        super.init()
        // Only initialize Sparkle if a real EdDSA public key is configured.
        // While the key is the build-time placeholder, Sparkle would pop a
        // modal "Unable to Check For Updates" on every launch.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.contains("PLACEHOLDER") else {
            NSLog("[Clipx] UpdateManager: SUPublicEDKey is a placeholder, Sparkle disabled in this build")
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        // Sparkle starts on init (when enabled). This call exists so AppDelegate
        // can express intent at launch.
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
#endif
