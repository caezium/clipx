#if DIRECT_BUILD
import Foundation
import Sparkle

/// Wraps SPUStandardUpdaterController so menu items and Settings can call
/// `checkForUpdates()` and let Sparkle manage the rest.
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()
    private var updaterController: SPUStandardUpdaterController?

    private override init() {
        super.init()
        // Only initialize Sparkle if a real EdDSA public key is configured.
        // While the key is the build-time placeholder, Sparkle would pop a
        // modal "Unable to Check For Updates" on every launch.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.contains("PLACEHOLDER") else {
            ClipxLog.updater.info("SUPublicEDKey is a placeholder, Sparkle disabled in this build")
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func start() {
        // Sparkle starts on init (when enabled). This call exists so AppDelegate
        // can express intent at launch.
    }

    func checkForUpdates() {
        guard let updaterController else {
            Task { @MainActor in
                AppState.shared.showToast("Update delivery isn't configured for this build", level: .info)
            }
            return
        }
        updaterController.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppPreferences.defaults.string(forKey: "updateChannel") == "beta" ? ["beta"] : []
    }

    func resetUpdateCycle() {
        updaterController?.updater.resetUpdateCycleAfterShortDelay()
    }
}
#endif
