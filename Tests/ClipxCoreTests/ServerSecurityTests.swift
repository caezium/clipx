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
}
