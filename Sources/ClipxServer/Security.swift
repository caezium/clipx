import Foundation
import CryptoKit
import Security
import Darwin

/// Constant-time string comparison — its running time depends only on the
/// longer input's length, never on the position of the first mismatch, so it
/// can't be used as a timing oracle to recover a secret byte-by-byte. (#2)
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8), bb = Array(b.utf8)
    var diff = ab.count ^ bb.count            // length mismatch ⇒ never equal
    let n = max(ab.count, bb.count)
    for i in 0..<n {
        let x = i < ab.count ? ab[i] : 0
        let y = i < bb.count ? bb[i] : 0
        diff |= Int(x ^ y)
    }
    return diff == 0
}

/// Clamp a client-supplied `limit` query param into a sane positive range. A
/// negative value would otherwise disable SQLite's LIMIT and dump the entire
/// table into one in-memory response. (#8)
func clampLimit(_ raw: String?, default def: Int = 300, max maxValue: Int = 1000) -> Int {
    guard let raw, let v = Int(raw) else { return def }
    return Swift.max(1, Swift.min(maxValue, v))
}

/// Whether the request's `Host` header targets this machine. Blocks
/// DNS-rebinding: an attacker page on `evil.com` whose DNS resolves to the
/// victim's LAN IP still sends `Host: evil.com`, which is not in this set. (#4)
func isAllowedHost(_ host: String?) -> Bool {
    guard let host, !host.isEmpty,
          !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return false }
    let name: String
    if host.hasPrefix("[") {
        guard let closing = host.firstIndex(of: "]") else { return false }
        name = String(host[host.index(after: host.startIndex)..<closing])
        let suffix = host[host.index(after: closing)...]
        guard validPortSuffix(String(suffix)) else { return false }
        var address = in6_addr()
        guard inet_pton(AF_INET6, name, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        // IPv6 equivalents of the existing loopback / private / link-local policy.
        return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            || bytes[0] & 0xfe == 0xfc
            || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
    let components = host.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count <= 2 else { return false }
    name = String(components[0])
    if components.count == 2, !validPortSuffix(":" + components[1]) { return false }
    let lower = name.lowercased()
    if lower == "localhost" || lower == "127.0.0.1" { return true }
    if lower.hasSuffix(".local"), lower.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
    }) { return true }
    return isPrivateIPv4(lower)                     // the Mac's LAN address
}

private func validPortSuffix(_ suffix: String) -> Bool {
    if suffix.isEmpty { return true }
    guard suffix.hasPrefix(":"), suffix.count > 1 else { return false }
    let digits = suffix.dropFirst()
    return digits.utf8.allSatisfy({ (48...57).contains($0) })
        && UInt16(digits).map { $0 > 0 } == true
}

/// Sliding-window failed-attempt throttle for PIN pairing. After
/// `maxAttempts` failures within `lockoutSeconds`, pairing is locked for that
/// window — turning a 1,000,000-value PIN from "guessable in minutes" into
/// "infeasible". A success clears the counter. (#1)
struct PairingThrottle {
    let maxAttempts: Int
    let lockoutSeconds: Double
    private var failures: [Double] = []
    private var lockedUntil: Double = 0

    init(maxAttempts: Int = 5, lockoutSeconds: Double = 60) {
        self.maxAttempts = maxAttempts
        self.lockoutSeconds = lockoutSeconds
    }

    func isLockedOut(now: Double) -> Bool { now < lockedUntil }

    mutating func recordFailure(now: Double) {
        failures = failures.filter { now - $0 < lockoutSeconds }   // drop stale
        failures.append(now)
        if failures.count >= maxAttempts {
            lockedUntil = now + lockoutSeconds
            failures.removeAll()
        }
    }

    mutating func recordSuccess() {
        failures.removeAll()
        lockedUntil = 0
    }
}

/// Stores session tokens as SHA-256 hashes with an issue time, so leaking the
/// persisted blob doesn't leak usable tokens, and tokens expire. Validation is
/// constant-time over the stored hashes. (#3)
struct SessionTokenStore: Codable {
    var ttl: Double
    private var entries: [String: Double]   // sha256(token) hex -> issuedAt epoch

    init(ttl: Double = 30 * 24 * 3600) {     // 30 days
        self.ttl = ttl
        self.entries = [:]
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func issue(_ token: String, now: Double) {
        prune(now: now)
        entries[Self.hash(token)] = now
        // Bound growth from repeated pairings.
        if entries.count > 64 {
            let oldest = entries.sorted { $0.value < $1.value }.prefix(entries.count - 64).map(\.key)
            for k in oldest { entries[k] = nil }
        }
    }

    func isValid(_ token: String, now: Double) -> Bool {
        let h = Self.hash(token)
        var ok = false
        for (k, issued) in entries where now - issued < ttl {
            if constantTimeEquals(h, k) { ok = true }
        }
        return ok
    }

    mutating func revokeAll() { entries.removeAll() }
    mutating func prune(now: Double) { entries = entries.filter { now - $0.value < ttl } }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> SessionTokenStore {
        (try? JSONDecoder().decode(SessionTokenStore.self, from: data)) ?? SessionTokenStore()
    }
}

/// Resolves a `Range` header (or its absence) into a concrete byte window,
/// always bounded by `maxChunk` so a single response never reads an entire
/// large file into memory. Returns nil for an unsatisfiable range. A request
/// with no Range gets a bounded first chunk (the browser continues with
/// Range requests). (#5)
func resolveByteRange(_ header: String?, size: Int64, maxChunk: Int64 = 1_048_576) -> (start: Int64, end: Int64)? {
    guard size > 0, maxChunk > 0 else { return nil }
    guard let header else {
        return (0, Swift.min(size - 1, maxChunk - 1))
    }
    guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
    let spec = String(header.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return nil }
    func decimal(_ raw: String) -> Int64? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(raw)
    }
    let start: Int64
    let requestedEnd: Int64
    if parts[0].isEmpty {
        guard let suffix = decimal(parts[1]), suffix > 0 else { return nil }
        start = size - Swift.min(size, suffix)
        requestedEnd = size - 1
    } else {
        guard let parsedStart = decimal(parts[0]), parsedStart < size else { return nil }
        start = parsedStart
        if parts[1].isEmpty { requestedEnd = size - 1 }
        else {
            guard let end = decimal(parts[1]), end >= start else { return nil }
            requestedEnd = Swift.min(size - 1, end)
        }
    }
    // Compute the length within EOF before adding it to the start. Even
    // Int64.max input cannot overflow this arithmetic.
    let count = Swift.min(maxChunk, requestedEnd - start + 1)
    return (start, start + (count - 1))
}

/// Extracts a single cookie value from a `Cookie:` header. Lets the web client
/// carry its session in a same-origin cookie instead of a `?token=` query
/// param that leaks into logs and Referer headers. (#6)
func cookieValue(_ cookieHeader: String?, name: String) -> String? {
    guard let cookieHeader else { return nil }
    for pair in cookieHeader.split(separator: ";") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2, kv[0] == name { return kv[1] }
    }
    return nil
}

/// Cryptographically-secure random token, hex-encoded. Uses the system CSPRNG
/// (`SecRandomCopyBytes`) rather than `randomElement()`. (#3)
func generateSecureToken(byteCount: Int = 24) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
        var rng = SystemRandomNumberGenerator()   // also CSPRNG on Apple platforms
        bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func isPrivateIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
    let octets = parts.compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    switch (octets[0], octets[1]) {
    case (10, _): return true
    case (192, 168): return true
    case (172, let b) where (16...31).contains(b): return true
    case (169, 254): return true   // link-local
    default: return false
    }
}
