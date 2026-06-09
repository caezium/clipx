import XCTest
@testable import Clipx

/// Behavioral tests for the embedded web server's auth/hardening helpers.
/// Each maps to a GitHub backlog issue (number noted per test).
final class ServerSecurityTests: XCTestCase {

    // MARK: #2 — constant-time comparison

    func test_constantTimeEquals_matchesOrdinaryEquality() {
        XCTAssertTrue(constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(constantTimeEquals("abc123", "abc124"))          // last byte differs
        XCTAssertFalse(constantTimeEquals("abc123", "Xbc123"))          // first byte differs
        XCTAssertFalse(constantTimeEquals("abc", "abcd"))               // length differs
        XCTAssertFalse(constantTimeEquals("", "x"))
        XCTAssertTrue(constantTimeEquals("", ""))
    }

    // MARK: #8 — limit clamping

    func test_clampLimit_rejectsNegativeAndZero() {
        XCTAssertEqual(clampLimit("-1", default: 300, max: 1000), 1)
        XCTAssertEqual(clampLimit("0", default: 300, max: 1000), 1)
    }

    func test_clampLimit_capsLargeValues() {
        XCTAssertEqual(clampLimit("999999", default: 300, max: 1000), 1000)
    }

    func test_clampLimit_passesSaneValueAndDefaults() {
        XCTAssertEqual(clampLimit("50", default: 300, max: 1000), 50)
        XCTAssertEqual(clampLimit(nil, default: 300, max: 1000), 300)
        XCTAssertEqual(clampLimit("notanumber", default: 300, max: 1000), 300)
    }

    // MARK: #4 — Host allowlist (DNS-rebinding defense)

    func test_isAllowedHost_acceptsLocalAndPrivateLAN() {
        XCTAssertTrue(isAllowedHost("localhost:7878"))
        XCTAssertTrue(isAllowedHost("127.0.0.1:7878"))
        XCTAssertTrue(isAllowedHost("192.168.1.42:7878"))
        XCTAssertTrue(isAllowedHost("10.0.0.5:7878"))
        XCTAssertTrue(isAllowedHost("172.16.3.9:7878"))
        XCTAssertTrue(isAllowedHost("henrys-mac.local:7878"))
    }

    func test_isAllowedHost_rejectsAttackerDomainsAndPublicIPs() {
        XCTAssertFalse(isAllowedHost("evil.com:7878"))        // DNS-rebind domain
        XCTAssertFalse(isAllowedHost("8.8.8.8:7878"))          // public IP
        XCTAssertFalse(isAllowedHost("172.32.0.1:7878"))       // just outside 172.16/12
        XCTAssertFalse(isAllowedHost(nil))
        XCTAssertFalse(isAllowedHost(""))
    }

    // MARK: #4 — no wildcard CORS

    func test_response_doesNotEmitWildcardCORS() {
        let wire = String(data: HTTPResponse.json(["ok": true]).serialize(), encoding: .utf8) ?? ""
        XCTAssertFalse(wire.contains("Access-Control-Allow-Origin: *"),
                       "wildcard CORS lets any website read responses")
    }

    // MARK: #1 — PIN brute-force throttle

    func test_pairingThrottle_locksOutAfterMaxFailures() {
        var t = PairingThrottle(maxAttempts: 3, lockoutSeconds: 60)
        XCTAssertFalse(t.isLockedOut(now: 0))
        t.recordFailure(now: 0)
        t.recordFailure(now: 1)
        XCTAssertFalse(t.isLockedOut(now: 2), "2 failures < threshold")
        t.recordFailure(now: 2)
        XCTAssertTrue(t.isLockedOut(now: 3), "3rd failure trips the lockout")
    }

    func test_pairingThrottle_clearsAfterCooldown() {
        var t = PairingThrottle(maxAttempts: 2, lockoutSeconds: 30)
        t.recordFailure(now: 0); t.recordFailure(now: 0)
        XCTAssertTrue(t.isLockedOut(now: 5))
        XCTAssertFalse(t.isLockedOut(now: 31), "lockout self-clears after cooldown")
    }

    func test_pairingThrottle_successResetsCounter() {
        var t = PairingThrottle(maxAttempts: 3, lockoutSeconds: 60)
        t.recordFailure(now: 0); t.recordFailure(now: 0)
        t.recordSuccess()
        t.recordFailure(now: 0); t.recordFailure(now: 0)
        XCTAssertFalse(t.isLockedOut(now: 0), "success cleared the prior failures")
    }

    // MARK: #3 — session token expiry / revocation / not-plaintext

    func test_sessionTokens_validWithinTTLInvalidAfter() {
        var s = SessionTokenStore(ttl: 100)
        s.issue("tok-abc", now: 0)
        XCTAssertTrue(s.isValid("tok-abc", now: 50))
        XCTAssertFalse(s.isValid("tok-abc", now: 150), "expired after TTL")
        XCTAssertFalse(s.isValid("unknown", now: 50))
    }

    func test_sessionTokens_revokeAllInvalidates() {
        var s = SessionTokenStore(ttl: 100)
        s.issue("tok", now: 0)
        s.revokeAll()
        XCTAssertFalse(s.isValid("tok", now: 1))
    }

    func test_sessionTokens_storedHashedNotPlaintext() {
        var s = SessionTokenStore(ttl: 100)
        s.issue("supersecret-token", now: 0)
        let blob = String(data: s.encoded(), encoding: .utf8) ?? ""
        XCTAssertFalse(blob.contains("supersecret-token"),
                       "tokens must be persisted hashed, not in plaintext")
    }

    func test_secureToken_isHexAndUnique() {
        let a = generateSecureToken(byteCount: 24)
        let b = generateSecureToken(byteCount: 24)
        XCTAssertEqual(a.count, 48, "24 bytes → 48 hex chars")
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.range(of: "[^0-9a-f]", options: .regularExpression))
    }

    // MARK: #7 — request size limit

    func test_httpRequest_flagsOversizeBuffer() {
        XCTAssertFalse(HTTPRequest.exceedsLimit(Data(count: 10)))
        XCTAssertTrue(HTTPRequest.exceedsLimit(Data(count: HTTPRequest.maxRequestBytes + 1)))
    }
}
