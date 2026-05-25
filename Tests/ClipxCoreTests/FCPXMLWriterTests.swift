import XCTest
@testable import Clipx

/// Tests the FCPXML number formatting and error reporting. The full
/// buildDocument path needs AppEnvironment.shared.database with real clips,
/// which the integration tests cover.
final class FCPXMLWriterTests: XCTestCase {
    func test_buildDocument_throwsOnEmptyClipList() {
        XCTAssertThrowsError(try FCPXMLWriter.buildDocument(clipIDs: [])) { error in
            XCTAssertTrue(error is FCPXMLWriter.FCPError)
        }
    }

    func test_rationalSeconds_integerFps() {
        // At 30fps, 60 frames = 60/30s = 2 seconds (FCPXML rational form).
        XCTAssertEqual(FCPXMLWriter.rationalSeconds(frames: 60, fps: 30), "60/30s")
    }

    func test_rationalSeconds_ntsc23976() {
        // 23.976 has the canonical 1001/24000 representation. 24 frames
        // should produce 24*1001 / 24000.
        let result = FCPXMLWriter.rationalSeconds(frames: 24, fps: 23.976)
        XCTAssertEqual(result, "24024/24000s", "expected NTSC rational form, got: \(result)")
    }

    func test_rationalSeconds_ntsc2997() {
        let result = FCPXMLWriter.rationalSeconds(frames: 30, fps: 29.97)
        XCTAssertEqual(result, "30030/30000s")
    }

    func test_rationalSeconds_ntsc5994() {
        let result = FCPXMLWriter.rationalSeconds(frames: 60, fps: 59.94)
        XCTAssertEqual(result, "60060/60000s")
    }

    func test_frameDurationRational_integerFps() {
        XCTAssertEqual(FCPXMLWriter.frameDurationRational(fps: 30), "1/30s")
        XCTAssertEqual(FCPXMLWriter.frameDurationRational(fps: 60), "1/60s")
    }

    func test_frameDurationRational_ntsc() {
        // One frame at 23.976 = 1001/24000s — was previously rounded to 1/23s.
        XCTAssertEqual(FCPXMLWriter.frameDurationRational(fps: 23.976), "1001/24000s")
        XCTAssertEqual(FCPXMLWriter.frameDurationRational(fps: 29.97),  "1001/30000s")
    }

    func test_missingMetadataError_includesPath() {
        let err: FCPXMLWriter.FCPError = .missingMetadata(sourcePath: "/tmp/no-meta.mov")
        XCTAssertTrue(err.errorDescription?.contains("/tmp/no-meta.mov") == true)
    }
}
