import Foundation

/// Pairing PIN store for the embedded web server.
///
/// First time the server starts with no PIN set, generates a random 6-digit
/// code shown in Settings. The web frontend prompts for it on first load and
/// stores the resulting token in localStorage; subsequent requests include
/// the token via `Authorization: Bearer <token>`. Stops drive-bys on a
/// shared Wi-Fi.
///
/// Not a real auth scheme — there's no rotation, no per-device tokens, and
/// PIN brute-force is rate-limited only by network. Good enough for "phone
/// on your home network" but not "exposed laptop in a hotel lobby". Don't
/// confuse defense-in-depth with real security.
@MainActor
final class PairingStore {
    static let shared = PairingStore()

    private static let pinKey = "webServerPairingPIN"
    private static let tokensKey = "webServerSessionTokens"

    /// Returns the current PIN, generating one on first call.
    var pin: String {
        if let existing = UserDefaults.standard.string(forKey: Self.pinKey),
           existing.count == 6 {
            return existing
        }
        let new = String(format: "%06d", Int.random(in: 0..<1_000_000))
        UserDefaults.standard.set(new, forKey: Self.pinKey)
        return new
    }

    /// Regenerates the PIN and invalidates all session tokens.
    func rotate() {
        let new = String(format: "%06d", Int.random(in: 0..<1_000_000))
        UserDefaults.standard.set(new, forKey: Self.pinKey)
        UserDefaults.standard.set([String](), forKey: Self.tokensKey)
    }

    /// Validates a candidate PIN and, if correct, mints a session token the
    /// client can present in subsequent requests.
    func authenticate(pin candidate: String) -> String? {
        guard constantTimeEquals(candidate, pin) else { return nil }
        // Token is high-entropy random; we don't need crypto-strong, just
        // unguessable.
        let token = (0..<32).map { _ in
            "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!
        }
        let tokenString = String(token)
        var tokens = UserDefaults.standard.stringArray(forKey: Self.tokensKey) ?? []
        tokens.append(tokenString)
        // Cap so the array can't grow forever if a malicious caller keeps
        // re-pairing.
        if tokens.count > 32 { tokens.removeFirst(tokens.count - 32) }
        UserDefaults.standard.set(tokens, forKey: Self.tokensKey)
        return tokenString
    }

    /// True if the candidate token was minted by a successful authenticate().
    /// Compares every stored token in constant time (no early exit) so token
    /// validation isn't a timing oracle either. (#2)
    func isValid(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let tokens = UserDefaults.standard.stringArray(forKey: Self.tokensKey) ?? []
        var ok = false
        for t in tokens where constantTimeEquals(token, t) { ok = true }
        return ok
    }
}
