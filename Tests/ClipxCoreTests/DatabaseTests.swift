import XCTest
@testable import Clipx_Direct

final class DatabaseTests: XCTestCase {
    func test_inMemoryDatabaseOpensAndMigrates() throws {
        let db = try Database.inMemory()
        try db.read { db in
            let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            let names = tables.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("sources"))
            XCTAssertTrue(names.contains("clips"))
            XCTAssertTrue(names.contains("tags"))
        }
    }

    func test_clipFTSRoundTrip() throws {
        let db = try Database.inMemory()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at)
                VALUES('/tmp/a.mov', 'h1', 0, 0)
            """)
            let srcID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO clips(source_id, in_ms, out_ms, name, mood, created_at)
                VALUES(?, 0, 5000, 'walk slow', 'melancholic', 0)
            """, arguments: [srcID])
        }
        let hits: [Int64] = try db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT rowid FROM clips_fts WHERE clips_fts MATCH 'walk*'
            """)
        }
        XCTAssertEqual(hits.count, 1)
    }
}
