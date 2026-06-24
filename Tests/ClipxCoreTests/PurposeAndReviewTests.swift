import XCTest
import GRDB
@testable import Clipx

/// Covers the v4 foundation: per-clip purpose CSV, per-source reviewed flag,
/// and the built-in purpose presets.
final class PurposeAndReviewTests: XCTestCase {
    var db: Clipx.Database!
    var sut: MarkerStore!
    var sourceID: Int64!

    override func setUpWithError() throws {
        db = try Database.inMemory()
        sut = MarkerStore(database: db)
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at, duration_ms, fps)
                VALUES('/tmp/test.mov', 'hashA', 0, 0, 60000, 30.0)
            """)
            sourceID = dbConn.lastInsertedRowID
        }
    }

    // MARK: purpose CSV

    func test_purpose_parsesCSVIntoList() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try sut.updatePurpose(clip.id!, purpose: "coach, reel")
        let reloaded = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded?.purposeList, ["coach", "reel"])
    }

    func test_togglePurpose_addsThenRemoves() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        var keys = try sut.togglePurpose(clip.id!, key: "coach")
        XCTAssertEqual(keys, ["coach"])
        keys = try sut.togglePurpose(clip.id!, key: "reel")
        XCTAssertEqual(keys, ["coach", "reel"])
        keys = try sut.togglePurpose(clip.id!, key: "coach")
        XCTAssertEqual(keys, ["reel"])
        // Removing the last key clears the column back to nil.
        keys = try sut.togglePurpose(clip.id!, key: "reel")
        XCTAssertEqual(keys, [])
        XCTAssertNil(try sut.fetchClip(clip.id!)?.purpose)
    }

    func test_clipCount_forSource() throws {
        XCTAssertEqual(try sut.clipCount(forSource: sourceID), 0)
        _ = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        _ = try sut.saveRange(sourceID: sourceID, inMs: 2000, outMs: 3000)
        XCTAssertEqual(try sut.clipCount(forSource: sourceID), 2)
    }

    // MARK: reviewed flag

    func test_markSourceReviewed_setsAndClears() throws {
        var src = try db.read { try Source.fetchOne($0, key: sourceID) }
        XCTAssertFalse(src?.isReviewed ?? true)

        try sut.markSourceReviewed(sourceID, reviewed: true)
        src = try db.read { try Source.fetchOne($0, key: sourceID) }
        XCTAssertTrue(src?.isReviewed ?? false)
        XCTAssertNotNil(src?.reviewedAt)

        try sut.markSourceReviewed(sourceID, reviewed: false)
        src = try db.read { try Source.fetchOne($0, key: sourceID) }
        XCTAssertFalse(src?.isReviewed ?? true)
        XCTAssertNil(src?.reviewedAt)
    }

    // MARK: presets

    func test_purposePresets_areNonEmptyAndUnique() {
        XCTAssertFalse(Purposes.all.isEmpty)
        for preset in Purposes.all {
            XCTAssertFalse(preset.labels.isEmpty, "\(preset.name) has no labels")
            let keys = preset.labels.map(\.key)
            XCTAssertEqual(Set(keys).count, keys.count, "\(preset.name) has duplicate keys")
        }
        // Creator is the general-purpose default and must exist.
        XCTAssertEqual(Purposes.creator.id, "creator")
    }

    func test_title_fallsBackToCapitalizedKey() {
        // Unknown keys (e.g. a label since removed from the active set) fall
        // back to a capitalized key so the chip still renders something sane.
        XCTAssertEqual(Purposes.title(forKey: "mystery"), "Mystery")
    }
}
