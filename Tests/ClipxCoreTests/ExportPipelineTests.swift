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

    // #16 — re-export must not reuse a path that already exists.
    func test_uniqueOutputURL_versionsOnCollision() {
        let dir = URL(fileURLWithPath: "/tmp/exports")
        var taken = Set<String>()
        let u1 = ExportPipeline.uniqueOutputURL(dir: dir, base: "clip-1", ext: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(u1.lastPathComponent, "clip-1.mp4")
        taken.insert(u1.path)
        let u2 = ExportPipeline.uniqueOutputURL(dir: dir, base: "clip-1", ext: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(u2.lastPathComponent, "clip-1-2.mp4", "prior render must survive")
        taken.insert(u2.path)
        let u3 = ExportPipeline.uniqueOutputURL(dir: dir, base: "clip-1", ext: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(u3.lastPathComponent, "clip-1-3.mp4")
    }

    // #17 — a record left "in progress" by a crash is reconciled to failed.
    func test_reconcileInterruptedExports_failsStuckInProgress() throws {
        let db = try Database.inMemory()
        try db.write { c in
            try c.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at) VALUES('/s','h',0,0)")
            let sid = c.lastInsertedRowID
            try c.execute(sql: "INSERT INTO clips(source_id,in_ms,out_ms,created_at) VALUES(?,0,1000,0)", arguments: [sid])
            let cid = c.lastInsertedRowID
            try c.execute(sql: "INSERT INTO exports(clip_id,preset,output_path,exported_at,status) VALUES(?,?,?,0,?)",
                          arguments: [cid, "reels", "/tmp/clipx-nope.mp4", ExportStatus.inProgress.rawValue])
            try c.execute(sql: "INSERT INTO exports(clip_id,preset,output_path,exported_at,status) VALUES(?,?,?,0,?)",
                          arguments: [cid, "reels", "/tmp/clipx-ok.mp4", ExportStatus.success.rawValue])
        }
        ExportPipeline.reconcileInterruptedExports(database: db)
        let statuses: [String] = try db.read { c in
            try String.fetchAll(c, sql: "SELECT status FROM exports ORDER BY id")
        }
        XCTAssertEqual(statuses, [ExportStatus.failed.rawValue, ExportStatus.success.rawValue],
                       "stuck in-progress → failed; success untouched")
    }
}
