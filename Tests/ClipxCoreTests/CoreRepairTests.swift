import XCTest
import GRDB
@testable import Clipx

final class CoreRepairTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipx-core-repair-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMigrationFailurePreservesOriginalDatabase() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("clipx.sqlite")
        let original = try DatabaseQueue(path: url.path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE sources (sentinel TEXT); INSERT INTO sources VALUES ('keep me')")
        }
        try original.close()
        XCTAssertThrowsError(try Clipx.Database.openOrRecover(at: url))
        let preserved = try DatabaseQueue(path: url.path)
        XCTAssertEqual(try preserved.read { try String.fetchOne($0, sql: "SELECT sentinel FROM sources") }, "keep me")
        try preserved.close()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("corrupt") })
    }

    func testLockedLibraryIsNotReplaced() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("clipx.sqlite")
        let original = try Clipx.Database.openOrRecover(at: url)
        try original.write { try $0.execute(sql: "INSERT INTO tags(name) VALUES ('preserve')") }
        try original.dbWriter.close()
        var lockConfig = Configuration()
        lockConfig.allowsUnsafeTransactions = true
        let lock = try DatabaseQueue(path: url.path, configuration: lockConfig)
        try lock.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE; BEGIN EXCLUSIVE") }
        XCTAssertThrowsError(try Clipx.Database.openOrRecover(at: url)) { error in
            XCTAssertFalse(Clipx.Database.isCorruption(error))
        }
        try lock.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        try lock.close()
        let reopened = try Clipx.Database.openOrRecover(at: url)
        XCTAssertEqual(try reopened.read { try String.fetchOne($0, sql: "SELECT name FROM tags") }, "preserve")
        try reopened.dbWriter.close()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("corrupt") })
    }

    func testBadPrimaryAndBackupRecoverOnceAndPreserveBoth() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("clipx.sqlite")
        let backup = dir.appendingPathComponent("clipx.backup.sqlite")
        let bad = Data("corrupt database".utf8)
        try bad.write(to: url)
        try bad.write(to: backup)
        let db = try Clipx.Database.openOrRecover(at: url)
        XCTAssertNotNil(db.recoveryMessage)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM clips") }, 0)
        let archived = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("clipx.backup.corrupt-") })
        db.writeBackup(of: url)
        XCTAssertEqual(try Data(contentsOf: archived), bad)
        try db.dbWriter.close()
        let next = try Clipx.Database.openOrRecover(at: url)
        XCTAssertNil(next.recoveryMessage)
        try next.dbWriter.close()
    }

    func testValidatedBackupRestoresMetadata() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("clipx.sqlite")
        let original = try Clipx.Database.openOrRecover(at: url)
        try original.write { try $0.execute(sql: "INSERT INTO tags(name) VALUES ('saved label')") }
        original.writeBackup(of: url)
        try original.dbWriter.close()
        // Destroy the entire primary file set. A healthy WAL can legitimately
        // repair a damaged main header before recovery is needed.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data("bad primary".utf8).write(to: url)
        let recovered = try Clipx.Database.openOrRecover(at: url)
        XCTAssertEqual(try recovered.read { try String.fetchOne($0, sql: "SELECT name FROM tags") }, "saved label")
        XCTAssertTrue(recovered.recoveryMessage?.contains("restored") == true)
        try recovered.dbWriter.close()
    }

    func testRelocatedFolderKeepsClipIdentityAndMetadata() throws {
        let db = try Clipx.Database.inMemory()
        let store = BookmarkStore(database: db)
        try db.write { db in
            try db.execute(sql: "INSERT INTO folders(id,path,bookmark,added_at) VALUES(1,'/old_footage',X'01',0)")
            try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at) VALUES(7,'/old_footage/day/a.mov','hash',0,0)")
            try db.execute(sql: "INSERT INTO clips(id,source_id,name,in_ms,out_ms,created_at) VALUES(9,7,'Keep this clip',0,1000,0)")
        }
        try store.relinkFolder(id: 1, to: URL(fileURLWithPath: "/new_footage"), bookmark: Data([2]))
        let source = try db.read { try Source.fetchOne($0, key: 7) }
        XCTAssertEqual(source?.path, "/new_footage/day/a.mov")
        let clip = try db.read { try Clip.fetchOne($0, key: 9) }
        XCTAssertEqual(clip?.name, "Keep this clip")
        XCTAssertEqual(clip?.sourceID, 7)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT path FROM folders WHERE id=1") }, "/new_footage")
    }

    func testRelocationCollisionRollsBackEveryPath() throws {
        let db = try Clipx.Database.inMemory()
        try db.write { db in
            try db.execute(sql: "INSERT INTO folders(id,path,bookmark,added_at) VALUES(1,'/old',X'01',0)")
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at) VALUES('/old/a.mov','a',0,0),('/new/a.mov','b',0,0)")
        }
        XCTAssertThrowsError(try BookmarkStore(database: db).relinkFolder(id: 1, to: URL(fileURLWithPath: "/new"), bookmark: Data()))
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT path FROM folders WHERE id=1") }, "/old")
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sources") }, 2)
    }

    func testFolderRelinkAndAvailabilityRespectCaseSensitiveNeighbours() async throws {
        let db = try Clipx.Database.inMemory()
        try db.write { db in
            try db.execute(sql: "INSERT INTO folders(id,path,bookmark,added_at) VALUES(1,'/volume/footage',X'01',0)")
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at) VALUES('/volume/footage/a.mov','a',0,0),('/volume/FOOTAGE/b.mov','b',0,0)")
        }
        let bookmarks = BookmarkStore(database: db)
        XCTAssertEqual(bookmarks.allFolders().first?.fileCount, 1)
        try bookmarks.relinkFolder(id: 1, to: URL(fileURLWithPath: "/volume/moved"), bookmark: Data([2]))
        let paths = try db.read { try String.fetchAll($0, sql: "SELECT path FROM sources ORDER BY id") }
        XCTAssertEqual(paths, ["/volume/moved/a.mov", "/volume/FOOTAGE/b.mov"])
        let indexer = Indexer(database: db, thumbnailEngine: ThumbnailEngine(database: db))
        await indexer.markFolderOffline("/volume/footage")
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT online FROM sources WHERE hash='b'") }, 1)
        await indexer.cancelPendingWork()
    }

    func testFullRescanRestoresUnchangedFileAndReconcilesRemoval() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("kept.mov")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let db = try Clipx.Database.inMemory()
        try db.write { db in
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,size,imported_at,online) VALUES(?,'a',100,3,0,0),(?,'b',100,3,0,1)",
                           arguments: [file.path, dir.appendingPathComponent("gone.mov").path])
            try db.execute(sql: "INSERT INTO folders(path,bookmark,added_at,online) VALUES(?,X'01',0,0)", arguments: [dir.path])
        }
        let indexer = Indexer(database: db, thumbnailEngine: ThumbnailEngine(database: db))
        let result = await indexer.index(folder: dir)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.indexed, 1)
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT path,online FROM sources ORDER BY id") }
        XCTAssertEqual(rows[0]["online"] as Int, 1, "Sources: \(rows)")
        XCTAssertEqual(rows.count, 2, "Sources: \(rows)")
        XCTAssertEqual(rows[1]["online"] as Int, 0)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT online FROM folders") }, 1)
        await indexer.cancelPendingWork()
    }

    func testRecentlyWrittenFileRetriesWithoutAnotherEvent() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("copy.mov")
        try Data([1, 2, 3]).write(to: file)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let mtime = Int64((attrs[.modificationDate] as! Date).timeIntervalSince1970)
        let db = try Clipx.Database.inMemory()
        try db.write { db in
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,size,imported_at,online) VALUES(?,'a',?,3,0,0)", arguments: [file.path, mtime])
        }
        let indexer = Indexer(database: db, thumbnailEngine: ThumbnailEngine(database: db))
        let changed = await indexer.indexFile(file)
        XCTAssertFalse(changed)
        try await Task.sleep(nanoseconds: 3_700_000_000)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT online FROM sources") }, 1)
        await indexer.cancelPendingWork()
    }

    func testCancelledLastFileDoesNotPublishScanAvailability() async throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("last.mov")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let db = try Clipx.Database.inMemory()
        try db.write { try $0.execute(sql: "INSERT INTO folders(path,bookmark,added_at,online) VALUES(?,X'01',0,1)", arguments: [dir.path]) }
        let started = expectation(description: "Metadata extraction began")
        let gate = MetadataGate()
        let indexer = Indexer(database: db, thumbnailEngine: ThumbnailEngine(database: db)) { _ in
            started.fulfill()
            await gate.wait()
            return MetadataExtractor.VideoMeta()
        }
        let scan = Task { await indexer.index(folder: dir) }
        await fulfillment(of: [started], timeout: 2)
        await indexer.cancelPendingWork()
        await indexer.markFolderOffline(dir.path)
        await gate.release()
        let result = await scan.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT online FROM folders") }, 0)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sources") }, 0)
        XCTAssertNil(try db.read { try Int64.fetchOne($0, sql: "SELECT last_scan_at FROM folders") })
    }

    func testDirectoryAndDroppedEventsRequireReconciliation() {
        for flags in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                      kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagItemIsDir,
                      kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagRootChanged] {
            XCTAssertTrue(FolderWatcher.Event(path: "/test", flags: UInt32(flags), id: 1).requiresRescan)
        }
        XCTAssertFalse(FolderWatcher.Event(path: "/test/a.mov", flags: UInt32(kFSEventStreamEventFlagItemIsFile), id: 1).requiresRescan)
    }

    func testExtremeLegacyClipDoesNotOverflow() {
        XCTAssertEqual(Clip(sourceID: 1, inMs: .min, outMs: .max, createdAt: 0).durationMs, 0)
        XCTAssertFalse(FileStability.isStable(mtimeEpoch: .min, now: .max))
        XCTAssertNil(FilenameDateParser.parse("20260230_clip.mov"))
        XCTAssertNotNil(FilenameDateParser.parse("20240229_clip.mov"))
    }

    func testInvalidPersistedPortsUseDefaultWithoutTrapping() {
        for port in [Int.min, -1, 0, 1023, 65536, Int.max] {
            XCTAssertEqual(AppEnvironment.validatedWebServerPort(port), 7878)
        }
        XCTAssertEqual(AppEnvironment.validatedWebServerPort(54321), 54321)
    }
}

private actor MetadataGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { opened = true; waiter?.resume(); waiter = nil }
}
