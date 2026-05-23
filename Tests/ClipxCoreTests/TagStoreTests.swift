import XCTest
@testable import Clipx

final class TagStoreTests: XCTestCase {
    var db: Clipx.Database!
    var sut: TagStore!
    var clipID: Int64!

    override func setUpWithError() throws {
        db = try Database.inMemory()
        sut = TagStore(database: db)
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at) VALUES('/tmp/x', 'h', 0, 0)
            """)
            let srcID = dbConn.lastInsertedRowID
            try dbConn.execute(sql: """
                INSERT INTO clips(source_id, in_ms, out_ms, created_at) VALUES(?, 0, 1000, 0)
            """, arguments: [srcID])
            clipID = dbConn.lastInsertedRowID
        }
    }

    func test_upsertTag_isCaseInsensitiveAndTrimmed() throws {
        let id1 = try sut.upsertTag(name: "  B-ROLL  ")
        let id2 = try sut.upsertTag(name: "b-roll")
        XCTAssertEqual(id1, id2)
    }

    func test_upsertTag_rejectsEmpty() {
        XCTAssertThrowsError(try sut.upsertTag(name: "   "))
    }

    func test_addAndRemoveTag_onClip() throws {
        try sut.addTag("Hands", toClip: clipID)
        try sut.addTag("Gesture", toClip: clipID)
        let tags = try sut.tags(forClip: clipID).map(\.name).sorted()
        XCTAssertEqual(tags, ["gesture", "hands"])

        try sut.removeTag("Hands", fromClip: clipID)
        let after = try sut.tags(forClip: clipID).map(\.name)
        XCTAssertEqual(after, ["gesture"])
    }

    func test_addingDuplicateTag_isIdempotent() throws {
        try sut.addTag("walk", toClip: clipID)
        try sut.addTag("walk", toClip: clipID)
        let tags = try sut.tags(forClip: clipID)
        XCTAssertEqual(tags.count, 1)
    }

    func test_suggestions_byPrefix() throws {
        try sut.upsertTag(name: "walking")
        try sut.upsertTag(name: "walkthrough")
        try sut.upsertTag(name: "talking")
        let suggestions = try sut.suggestions(prefix: "walk").map(\.name).sorted()
        XCTAssertEqual(suggestions, ["walking", "walkthrough"])
    }
}
