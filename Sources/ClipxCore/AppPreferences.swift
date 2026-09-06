import Foundation
import CryptoKit

/// One explicit environment override isolates app-driven verification from the
/// user's real library, preferences and thumbnail/proxy caches.
enum AppPreferences {
    static let dataDirectory: URL? = {
        if ProcessInfo.processInfo.environment["CLIPX_ISOLATED_TESTS"] == "1" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("clipx-verification-\(UUID().uuidString)", isDirectory: true)
        }
        guard let path = ProcessInfo.processInfo.environment["CLIPX_DATA_DIRECTORY"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static let defaults: UserDefaults = {
        guard let dataDirectory else { return .standard }
        let digest = SHA256.hash(data: Data(dataDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        // UserDefaults accepts this fixed-format suite; never fall back to the
        // user's real preferences if isolation was explicitly requested.
        return UserDefaults(suiteName: "com.clipx.verification.\(digest)")!
    }()

    static var cacheDirectory: URL? { dataDirectory?.appendingPathComponent("Caches", isDirectory: true) }
}
