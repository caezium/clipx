import XCTest
@testable import Clipx

/// Tests static helpers on ExportPipeline. The job-running path requires
/// AVFoundation + a real video file and is exercised by the integration
/// build; here we cover the bits that get hit on every export.
///
/// MainActor-isolated because ExportPipeline carries that annotation and
/// statics inherit isolation in Swift 5.10.
@MainActor
final class ExportPipelineTests: XCTestCase {
    func test_sanitizeFilename_stripsPathSeparators() {
        XCTAssertEqual(ExportPipeline.sanitizeFilename("a/b\\c"), "a-b-c")
    }

    func test_sanitizeFilename_stripsDotDotTraversal() {
        // The killer case — without `..` stripping, the file would write
        // outside outputDir.
        let result = ExportPipeline.sanitizeFilename("../../etc/passwd")
        XCTAssertFalse(result.contains(".."), "got: \(result)")
    }

    func test_sanitizeFilename_stripsLeadingDots() {
        // ".hidden" → "hidden" so we don't end up with macOS-invisible files.
        XCTAssertEqual(ExportPipeline.sanitizeFilename(".profile"), "profile")
    }

    func test_sanitizeFilename_emptyInputGivesFallback() {
        XCTAssertEqual(ExportPipeline.sanitizeFilename(""), "clip")
        XCTAssertEqual(ExportPipeline.sanitizeFilename("   "), "clip")
    }

    func test_sanitizeFilename_keepsSafeChars() {
        XCTAssertEqual(ExportPipeline.sanitizeFilename("My Best Clip 2026"), "My Best Clip 2026")
    }

    func test_sanitizeFilename_stripsControlChars() {
        // Tab and bell shouldn't make it into a filename even though they're
        // legal on disk — they break copy/paste and shell scripts.
        let dirty = "a\tb\u{0007}c"
        let clean = ExportPipeline.sanitizeFilename(dirty)
        XCTAssertFalse(clean.contains("\t"))
        XCTAssertFalse(clean.contains("\u{0007}"))
    }
}
