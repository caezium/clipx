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

    func testInterruptedHistoryCannotDeleteSuccessfulRetryAtSamePath() throws {
        let folder = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("retry.mp4")
        let completed = Data("successful retry".utf8)
        try completed.write(to: output)
        let database = try Database.inMemory()
        try database.write { db in
            for status in [ExportStatus.inProgress, .success] {
                try db.execute(sql: "INSERT INTO exports(preset,output_path,exported_at,status) VALUES('reels',?,0,?)",
                               arguments: [output.path, status.rawValue])
            }
        }
        ExportPipeline.reconcileInterruptedExports(database: database)
        XCTAssertEqual(try Data(contentsOf: output), completed)
        XCTAssertEqual(try database.read { try String.fetchAll($0, sql: "SELECT status FROM exports ORDER BY id") },
                       [ExportStatus.failed.rawValue, ExportStatus.success.rawValue])
    }
}

@MainActor
final class ExportLifecycleTests: XCTestCase {
    private actor Gate {
        private(set) var calls = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func enter() async {
            calls += 1
            if calls == 1 { await withCheckedContinuation { waiter = $0 } }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    func testCancelThenEnqueueWaitsForCleanupAndWritesTerminalHistory() async throws {
        let database = try databaseWithClip()
        let folder = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = Gate()
        let pipeline = ExportPipeline(database: database) { request, _, progress in
            try Data([1, 2, 3]).write(to: request.outputURL)
            await gate.enter()
            progress(0.75)
            return ClipRenderResult(durationMs: 1234, bytes: 3)
        }
        pipeline.enqueue(clipID: 1, preset: .reels, outputDir: folder)
        for _ in 0..<200 {
            if await gate.calls == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = await gate.calls
        XCTAssertEqual(started, 1)
        pipeline.cancelAll()
        pipeline.enqueue(clipID: 1, preset: .reels, outputDir: folder)
        XCTAssertTrue(pipeline.isRunning, "Cancelled worker stays active until it drains")
        XCTAssertTrue(pipeline.isCancelling)
        XCTAssertEqual(pipeline.jobs.count, 1)
        let callsBeforeRelease = await gate.calls
        XCTAssertEqual(callsBeforeRelease, 1, "A second worker must not overlap old cleanup")
        await gate.release()
        await drain(pipeline)
        let records = try database.read { try ExportRecord.fetchAll($0, sql: "SELECT * FROM exports ORDER BY id") }
        XCTAssertEqual(records.map(\.status), [ExportStatus.cancelled.rawValue, ExportStatus.success.rawValue])
        XCTAssertEqual(records.last?.durationMs, 1234, "History records measured output duration")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        XCTAssertEqual(try database.read { try Clip.fetchOne($0, key: 1)?.usedCount }, 1)
        XCTAssertNil(pipeline.currentJob)
        XCTAssertTrue(pipeline.progress.isEmpty)
    }

    func testFailureRemovesPartialOutputAndClosesHistory() async throws {
        let database = try databaseWithClip()
        let folder = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = ExportPipeline(database: database) { request, _, _ in
            try Data([1]).write(to: request.outputURL)
            throw CocoaError(.fileWriteUnknown)
        }
        pipeline.enqueue(clipID: 1, preset: .reels, outputDir: folder)
        await drain(pipeline)
        let statuses = try database.read { try String.fetchAll($0, sql: "SELECT status FROM exports") }
        XCTAssertEqual(statuses, [ExportStatus.failed.rawValue])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testFailureAndPublicationCollisionPreserveOtherWriterAtFinalPath() async throws {
        for failBeforePublication in [true, false] {
            let database = try databaseWithClip()
            let folder = try MediaRegressionTests.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let otherFile = Data("Another process owns this file".utf8)
            let pipeline = ExportPipeline(database: database) { request, _, _ in
                try Data([1, 2, 3]).write(to: request.outputURL)
                let finalPath = try database.read {
                    try String.fetchOne($0, sql: "SELECT output_path FROM exports ORDER BY id DESC LIMIT 1")!
                }
                try otherFile.write(to: URL(fileURLWithPath: finalPath))
                if failBeforePublication { throw CocoaError(.fileWriteUnknown) }
                return ClipRenderResult(durationMs: 1234, bytes: 3)
            }
            pipeline.enqueue(clipID: 1, preset: .reels, outputDir: folder)
            await drain(pipeline)
            let entry = try database.read { try ExportRecord.fetchOne($0) }
            XCTAssertEqual(entry?.status, ExportStatus.failed.rawValue)
            let path = try XCTUnwrap(entry?.outputPath)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), otherFile)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        }
    }

    private func databaseWithClip() throws -> Database {
        let database = try Database.inMemory()
        try database.write { db in
            try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at,duration_ms,fps,speed) VALUES(1,'/fixture','fixture',0,0,8000,30,2)")
            try db.execute(sql: "INSERT INTO clips(id,source_id,in_ms,out_ms,created_at) VALUES(1,1,2000,6000,0)")
        }
        return database
    }

    private func drain(_ pipeline: ExportPipeline) async {
        for _ in 0..<400 {
            if !pipeline.isRunning { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Export queue did not drain")
    }
}
