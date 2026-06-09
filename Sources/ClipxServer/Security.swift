import Foundation

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
    guard let host, !host.isEmpty else { return false }
    let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
    let lower = name.lowercased()
    if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" { return true }
    if lower.hasSuffix(".local") { return true }   // Bonjour / mDNS name
    return isPrivateIPv4(lower)                     // the Mac's LAN address
}

private func isPrivateIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".").map(String.init)
    guard parts.count == 4 else { return false }
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
