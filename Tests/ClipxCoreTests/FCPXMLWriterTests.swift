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

final class FCPXMLDocumentTests: XCTestCase {
    func testOneFrameSelectionAndModernAssetSchema() throws {
        var source = MediaRegressionTests.source(path: "/tmp/a & b#c.mov")
        source.audioChannels = 0
        let clip = Clip(id: 1, sourceID: 1, name: "Take & review\u{1}", inMs: 33, outMs: 67, createdAt: 0)
        let text = try FCPXMLWriter.buildDocument(items: [(clip, source)])
        let document = try XMLDocument(xmlString: text)
        XCTAssertEqual(document.rootElement()?.attribute(forName: "version")?.stringValue, "1.10")
        let asset = try XCTUnwrap(document.nodes(forXPath: "//asset").first as? XMLElement)
        XCTAssertNil(asset.attribute(forName: "src"))
        XCTAssertEqual(asset.attribute(forName: "hasAudio")?.stringValue, "0")
        let media = try XCTUnwrap(document.nodes(forXPath: "//asset/media-rep").first as? XMLElement)
        XCTAssertEqual(media.attribute(forName: "src")?.stringValue, URL(fileURLWithPath: source.path).absoluteString)
        let item = try XCTUnwrap(document.nodes(forXPath: "//asset-clip").first as? XMLElement)
        XCTAssertEqual(item.attribute(forName: "start")?.stringValue, "1/30s")
        XCTAssertEqual(item.attribute(forName: "duration")?.stringValue, "1/30s")
    }

    func testMixedRateSequenceOffsetsUseOneFrameGrid() throws {
        var first = MediaRegressionTests.source(path: "/first.mov")
        first.fps = 30
        var second = MediaRegressionTests.source(path: "/second.mov")
        second.fps = 23.976
        let a = Clip(id: 1, sourceID: 1, inMs: 0, outMs: 33, createdAt: 0)
        let b = Clip(id: 2, sourceID: 1, inMs: 42, outMs: 1043, createdAt: 0)
        let document = try XMLDocument(xmlString: FCPXMLWriter.buildDocument(items: [(a, first), (b, second), (a, first)]))
        let clips = try document.nodes(forXPath: "//asset-clip").compactMap { $0 as? XMLElement }
        XCTAssertEqual(clips.map { $0.attribute(forName: "offset")?.stringValue }, ["0/30s", "1/30s", "31/30s"])
        XCTAssertEqual(clips[1].attribute(forName: "start")?.stringValue, "1001/24000s")
        let sequence = try XCTUnwrap(document.nodes(forXPath: "//sequence").first as? XMLElement)
        XCTAssertEqual(sequence.attribute(forName: "duration")?.stringValue, "32/30s")
    }
}
