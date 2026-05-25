import XCTest
@testable import Clipx

final class ObsidianWriterTests: XCTestCase {
    func test_obsidianTimecode_formatsHoursMinutesSeconds() {
        // Frame portion now correctly tracks sub-second milliseconds at the
        // given fps. At 65_500ms with the default 30fps, the 500ms remainder
        // produces 15 frames. Previously integer-truncated to 0 always.
        XCTAssertEqual(ObsidianWriter.formatTimecode(0), "00:00:00:00")
        XCTAssertEqual(ObsidianWriter.formatTimecode(65_500), "00:01:05:15")
        XCTAssertEqual(ObsidianWriter.formatTimecode(3_600_000), "01:00:00:00")
    }

    func test_obsidianTimecode_framesNonZeroWithFps() {
        // (ms % 1000) * fps / 1000 — previously this was integer-truncated to
        // 0. At 500ms past the second mark and 30fps, we expect 15 frames.
        XCTAssertEqual(ObsidianWriter.formatTimecode(500, fps: 30), "00:00:00:15")
    }

    func test_obsidianSanitize_stripsDotDot() {
        // Defense-in-depth alongside the path containment check.
        let result = ObsidianWriter.sanitize("../../etc/passwd")
        XCTAssertFalse(result.contains(".."))
        XCTAssertFalse(result.hasPrefix("."))
    }
}
