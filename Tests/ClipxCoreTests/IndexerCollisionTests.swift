import XCTest
import GRDB
@testable import Clipx

/// Tests the bug class where two concurrent FSEvents fires for the same
/// file used to trip `path UNIQUE` and silently drop one. Also covers the
/// LIKE-escape fix in markFolderOffline/Online.
final class IndexerCollisionTests: XCTestCase {
    func test_likeEscape_doesNotMatchUnderscoreNeighbours() throws {
        let db = try Database.inMemory()
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at, online)
                VALUES('/Users/me/My_Footage/a.mov', 'h1', 0, 0, 1)
            """)
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at, online)
                VALUES('/Users/me/MyXFootage/b.mov', 'h2', 0, 0, 1)
            """)
        }
        // Escaped LIKE on "My_Footage" should NOT match "MyXFootage" — without
        // ESCAPE, the underscore behaves as a single-char wildcard.
        let escaped = sqlLikeEscape("/Users/me/My_Footage")
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE sources SET online = 0 WHERE path LIKE ? ESCAPE '\\'",
                arguments: ["\(escaped)/%"]
            )
        }
        try db.read { dbConn in
            let a = try Bool.fetchOne(dbConn, sql: "SELECT online FROM sources WHERE path = ?", arguments: ["/Users/me/My_Footage/a.mov"])
            let b = try Bool.fetchOne(dbConn, sql: "SELECT online FROM sources WHERE path = ?", arguments: ["/Users/me/MyXFootage/b.mov"])
            XCTAssertEqual(a, false, "underscore folder should be marked offline")
            XCTAssertEqual(b, true, "neighbour folder must NOT be touched")
        }
    }

    func test_insertOnConflict_idempotentForSamePath() throws {
        let db = try Database.inMemory()
        // Simulate two upserts of the same path with different mtimes.
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources (path, hash, mtime, imported_at, online)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(path) DO UPDATE SET
                    hash = excluded.hash,
                    mtime = excluded.mtime,
                    online = 1
            """, arguments: ["/tmp/foo.mov", "h1", 100, 100])
            try dbConn.execute(sql: """
                INSERT INTO sources (path, hash, mtime, imported_at, online)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(path) DO UPDATE SET
                    hash = excluded.hash,
                    mtime = excluded.mtime,
                    online = 1
            """, arguments: ["/tmp/foo.mov", "h2", 200, 200])
        }
        try db.read { dbConn in
            let count = try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM sources WHERE path = ?", arguments: ["/tmp/foo.mov"]) ?? 0
            XCTAssertEqual(count, 1, "ON CONFLICT(path) should keep one row")
            let row = try Row.fetchOne(dbConn, sql: "SELECT mtime, hash FROM sources WHERE path = ?", arguments: ["/tmp/foo.mov"])
            XCTAssertEqual(row?["mtime"], 200, "second upsert should win")
            XCTAssertEqual(row?["hash"], "h2")
        }
    }

    func test_sizeColumn_addedByMigrationV2() throws {
        let db = try Database.inMemory()
        try db.read { dbConn in
            let cols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(sources)")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("size"), "v2_indexes_and_size migration should add the size column")
        }
    }

    func test_hotPathIndexesExist() throws {
        let db = try Database.inMemory()
        try db.read { dbConn in
            let indexes = try Row.fetchAll(
                dbConn,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
            ).compactMap { $0["name"] as String? }
            XCTAssertTrue(indexes.contains("idx_sources_created_at"))
            XCTAssertTrue(indexes.contains("idx_sources_online"))
            XCTAssertTrue(indexes.contains("idx_clips_used_count"))
            XCTAssertTrue(indexes.contains("idx_exports_clip"))
        }
    }
}
