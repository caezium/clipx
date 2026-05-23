import XCTest
@testable import Clipx

final class FCPXMLWriterTests: XCTestCase {
    func test_buildDocument_emptyClipList_producesValidShell() throws {
        let doc = try FCPXMLWriter.buildDocument(clipIDs: [])
        XCTAssertTrue(doc.contains("<fcpxml version=\"1.13\">"))
        XCTAssertTrue(doc.contains("<library>"))
        XCTAssertTrue(doc.contains("</fcpxml>"))
    }

    func test_obsidianTimecode_formatsHoursMinutesSeconds() {
        XCTAssertEqual(ObsidianWriter.formatTimecode(0), "00:00:00:00")
        XCTAssertEqual(ObsidianWriter.formatTimecode(65_500), "00:01:05:00")
        XCTAssertEqual(ObsidianWriter.formatTimecode(3_600_000), "01:00:00:00")
    }
}
