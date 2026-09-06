import Foundation

/// Pairing PIN store for the embedded web server.
///
/// First time the server starts with no PIN set, generates a random 6-digit
/// code shown in Settings. The web frontend prompts for it on first load and
/// stores the resulting token in localStorage; subsequent requests include
/// the token via `Authorization: Bearer <token>`. Stops drive-bys on a
/// shared Wi-Fi.
///
/// PIN rotation revokes all tokens. Pair attempts are throttled and issued
/// tokens are hashed at rest with an expiry time.
@MainActor
final class PairingStore {
    static let shared = PairingStore()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    private static let pinKey = "webServerPairingPIN"
    /// v2 store: hashed tokens with issue times (was a plaintext array). (#3)
    private static let tokenStoreKey = "webServerTokenStoreV2"

    /// Per-process failed-attempt throttle. In-memory is fine: a restart that
    /// clears it also drops any in-flight brute force. (#1)
    private var throttle = PairingThrottle(maxAttempts: 5, lockoutSeconds: 60)

    /// Returns the current PIN, generating one on first call.
    var pin: String {
        if let existing = defaults.string(forKey: Self.pinKey),
           existing.count == 6, existing.utf8.allSatisfy({ (48...57).contains($0) }) {
            return existing
        }
        let new = String(format: "%06d", Int.random(in: 0..<1_000_000))
        defaults.set(new, forKey: Self.pinKey)
        return new
    }

    /// Regenerates the PIN and revokes all session tokens.
    func rotate() {
        let new = String(format: "%06d", Int.random(in: 0..<1_000_000))
        defaults.set(new, forKey: Self.pinKey)
        var store = loadTokens()
        store.revokeAll()
        saveTokens(store)
    }

    /// True when repeated failed pairings have tripped the lockout. The pairing
    /// route surfaces this as 429 so even a correct PIN is refused. (#1)
    func isLockedOut() -> Bool {
        throttle.isLockedOut(now: Date().timeIntervalSince1970)
    }

    /// Validates a candidate PIN and, if correct, mints a session token. Failed
    /// attempts are throttled; the PIN is compared in constant time. (#1, #2)
    func authenticate(pin candidate: String) -> String? {
        let now = Date().timeIntervalSince1970
        if throttle.isLockedOut(now: now) { return nil }
        guard constantTimeEquals(candidate, pin) else {
            throttle.recordFailure(now: now)
            return nil
        }
        throttle.recordSuccess()
        let token = generateSecureToken()         // CSPRNG (#3)
        var store = loadTokens()
        store.issue(token, now: now)              // stored hashed + with TTL (#3)
        saveTokens(store)
        return token
    }

    /// True if the candidate token was minted recently enough and not revoked.
    /// Comparison runs in constant time over stored hashes. (#2, #3)
    func isValid(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return loadTokens().isValid(token, now: Date().timeIntervalSince1970)
    }

    private func loadTokens() -> SessionTokenStore {
        guard let data = defaults.data(forKey: Self.tokenStoreKey) else {
            return SessionTokenStore()
        }
        return SessionTokenStore.decode(data)
    }

    private func saveTokens(_ store: SessionTokenStore) {
        defaults.set(store.encoded(), forKey: Self.tokenStoreKey)
    }
}
