import XCTest
import GRDB
@testable import Clipx

final class DatabaseTests: XCTestCase {
    func test_inMemoryDatabaseOpensAndMigrates() throws {
        let db = try Clipx.Database.inMemory()
        try db.read { dbConn in
            let tables = try Row.fetchAll(dbConn, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            let names = tables.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("sources"))
            XCTAssertTrue(names.contains("clips"))
            XCTAssertTrue(names.contains("tags"))
            XCTAssertTrue(names.contains("collections"))
            XCTAssertTrue(names.contains("projects"))
            XCTAssertTrue(names.contains("exports"))
            XCTAssertTrue(names.contains("folders"))
        }
    }

    func test_clipFTSRoundTrip() throws {
        let db = try Clipx.Database.inMemory()
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at)
                VALUES('/tmp/a.mov', 'h1', 0, 0)
            """)
            let srcID = dbConn.lastInsertedRowID
            try dbConn.execute(sql: """
                INSERT INTO clips(source_id, in_ms, out_ms, name, mood, created_at)
                VALUES(?, 0, 5000, 'walk slow', 'melancholic', 0)
            """, arguments: [srcID])
        }
        let hits: [Int64] = try db.read { dbConn in
            try Int64.fetchAll(dbConn, sql: """
                SELECT rowid FROM clips_fts WHERE clips_fts MATCH 'walk*'
            """)
        }
        XCTAssertEqual(hits.count, 1)
    }

    func test_foreignKey_cascadesDeleteOnSourceRemoval() throws {
        let db = try Clipx.Database.inMemory()
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at)
                VALUES('/tmp/b.mov', 'h2', 0, 0)
            """)
            let srcID = dbConn.lastInsertedRowID
            try dbConn.execute(sql: """
                INSERT INTO clips(source_id, in_ms, out_ms, created_at)
                VALUES(?, 0, 1000, 0)
            """, arguments: [srcID])
            try dbConn.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [srcID])
            let count = try Int.fetchOne(dbConn, sql: "SELECT count(*) FROM clips") ?? -1
            XCTAssertEqual(count, 0)
        }
    }
}
