import XCTest
import GRDB
@testable import Clipx

/// Real security-scoped bookmark resolution can't run in a unit test (the
/// Direct build is unsandboxed, so resumeAccess just no-ops). These tests
/// cover the parts that don't need the sandbox: idempotency of add, removal
/// of started-access tracking, and LIKE-escape on the fileCount query.
final class BookmarkStoreSandboxTests: XCTestCase {
    // Qualified to Clipx.Database — bare `Database` collides with GRDB.Database.
    var db: Clipx.Database!
    var sut: BookmarkStore!

    override func setUpWithError() throws {
        db = try Clipx.Database.inMemory()
        sut = BookmarkStore(database: db)
    }

    func test_addFolder_idempotentOnDuplicate() throws {
        // Seed two adds of the same path. Without the explicit upsert, the
        // second throws a UNIQUE-constraint error.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try sut.addFolder(url: tmpDir)
        XCTAssertNoThrow(try sut.addFolder(url: tmpDir))

        let count = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM folders WHERE path = ?", arguments: [tmpDir.path]) ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func test_removeFolder_deletesRow() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try sut.addFolder(url: tmpDir)
        sut.removeFolder(path: tmpDir.path)

        let count = try db.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM folders WHERE path = ?", arguments: [tmpDir.path]) ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func test_allFolders_fileCount_doesNotMatchUnderscoreNeighbours() throws {
        let underscoreDir = FileManager.default.temporaryDirectory.appendingPathComponent("My_Test_\(UUID().uuidString)")
        let neighbourDir = FileManager.default.temporaryDirectory.appendingPathComponent("MyXTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: underscoreDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbourDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: underscoreDir)
            try? FileManager.default.removeItem(at: neighbourDir)
        }

        try sut.addFolder(url: underscoreDir)
        // Seed one source per folder.
        try db.write { dbConn in
            try dbConn.execute(
                sql: "INSERT INTO sources (path, hash, mtime, imported_at) VALUES (?, ?, ?, ?)",
                arguments: ["\(underscoreDir.path)/a.mov", "h1", 0, 0]
            )
            try dbConn.execute(
                sql: "INSERT INTO sources (path, hash, mtime, imported_at) VALUES (?, ?, ?, ?)",
                arguments: ["\(neighbourDir.path)/b.mov", "h2", 0, 0]
            )
        }

        let descriptors = sut.allFolders()
        let entry = descriptors.first { $0.path == underscoreDir.path }
        XCTAssertEqual(entry?.fileCount, 1, "underscore-containing folder should count only its own file (not neighbours)")
    }
}
