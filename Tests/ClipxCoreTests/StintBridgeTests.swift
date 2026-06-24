import XCTest
@testable import Clipx

/// Covers the pure request-construction of the Clipx → Stint bridge. The live
/// HTTP round-trip is validated against a running Stint server, not here.
final class StintBridgeTests: XCTestCase {
    private let base = URL(string: "http://stint.local:4040")!

    func test_shareURL_matchesStintRouteAndTokenAuth() {
        let url = StintBridge.shareURL(base: base, projectID: "abc123", shareToken: "tok_XYZ")
        XCTAssertEqual(url.absoluteString, "http://stint.local:4040/p/abc123?t=tok_XYZ")
    }

    func test_ownerCookieHeader_format() {
        XCTAssertEqual(
            StintBridge.ownerCookieHeader(projectID: "p1", ownerKey: "ownerKEY"),
            "owner_p1=ownerKEY"
        )
    }

    func test_multipartVideoBody_containsBoundaryFieldsAndFileBytes() {
        let fileBytes = Data([0x00, 0x01, 0x02, 0xFF])
        let body = StintBridge.multipartVideoBody(
            fieldName: "video",
            filename: "clip.mp4",
            mimeType: "video/mp4",
            fileData: fileBytes,
            extraFields: ["durationSeconds": "8.500"],
            boundary: "BOUND"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BOUND\r\n"))
        XCTAssertTrue(text.contains("name=\"durationSeconds\""))
        XCTAssertTrue(text.contains("8.500"))
        XCTAssertTrue(text.contains("name=\"video\"; filename=\"clip.mp4\""))
        XCTAssertTrue(text.contains("Content-Type: video/mp4"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        // The raw file bytes survive intact inside the body.
        XCTAssertTrue(body.range(of: fileBytes) != nil)
    }

    func test_config_isNilWhenURLUnset() {
        let key = "stintServerURL"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.set("", forKey: key)
        XCTAssertNil(StintBridge.Config.current)

        UserDefaults.standard.set("not a url", forKey: key)
        XCTAssertNil(StintBridge.Config.current)

        UserDefaults.standard.set("http://stint.local:4040", forKey: key)
        XCTAssertEqual(StintBridge.Config.current?.baseURL.absoluteString, "http://stint.local:4040")
    }
}
