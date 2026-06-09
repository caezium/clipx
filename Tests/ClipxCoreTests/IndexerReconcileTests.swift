import XCTest
import GRDB
@testable import Clipx

final class IndexerReconcileTests: XCTestCase {
    // #21 — deleted/moved files stop showing as online; present ones stay.
    func test_reconcileMissingSources_offlinesDeletedKeepsExisting() async throws {
        let db = try Database.inMemory()
        let idx = Indexer(database: db, thumbnailEngine: ThumbnailEngine(database: db))
        let real = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipx-real-\(UUID()).mov")
        try Data([0, 1, 2]).write(to: real)
        defer { try? FileManager.default.removeItem(at: real) }

        try db.write { c in
            try c.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at,online) VALUES('/no/such/clipx.mov','h1',0,0,1)")
            try c.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at,online) VALUES(?,?,0,0,1)", arguments: [real.path, "h2"])
        }

        let changed = await idx.reconcileMissingSources()
        XCTAssertEqual(changed, 1)
        let rows = try db.read { c in try Row.fetchAll(c, sql: "SELECT online FROM sources ORDER BY id") }
        XCTAssertEqual(rows[0]["online"], false, "missing file → offline")
        XCTAssertEqual(rows[1]["online"], true, "present file stays online")
    }

    // #20 — a file modified within the stability window is deferred.
    func test_fileStability_defersRecentlyModified() {
        XCTAssertFalse(FileStability.isStable(mtimeEpoch: 100, now: 101))  // 1s old → still copying
        XCTAssertTrue(FileStability.isStable(mtimeEpoch: 100, now: 105))   // 5s old → settled
    }
}
