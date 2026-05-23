import XCTest
import GRDB
@testable import Clipx

final class MarkerStoreTests: XCTestCase {
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

    func test_saveRange_succeedsForValidRange() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 1000, outMs: 5000, name: "test")
        XCTAssertNotNil(clip.id)
        XCTAssertEqual(clip.durationMs, 4000)
    }

    func test_saveRange_throwsForInvertedRange() {
        XCTAssertThrowsError(try sut.saveRange(sourceID: sourceID, inMs: 5000, outMs: 1000))
    }

    func test_saveRange_throwsForZeroDuration() {
        XCTAssertThrowsError(try sut.saveRange(sourceID: sourceID, inMs: 1000, outMs: 1000))
    }

    func test_updateRating_clampsToValidRange() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try sut.updateRating(clip.id!, rating: 99)
        let reloaded = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded?.rating, 5)

        try sut.updateRating(clip.id!, rating: -10)
        let reloaded2 = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded2?.rating, 0)
    }

    func test_updateColorLabel_persistsValue() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try sut.updateColorLabel(clip.id!, label: 3)
        let reloaded = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded?.colorLabel, 3)
        try sut.updateColorLabel(clip.id!, label: nil)
        let cleared = try sut.fetchClip(clip.id!)
        XCTAssertNil(cleared?.colorLabel)
    }

    func test_updateRange_validation() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 1000, outMs: 5000)
        try sut.updateRange(clip.id!, inMs: 0, outMs: 2000)
        let reloaded = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded?.inMs, 0)
        XCTAssertEqual(reloaded?.outMs, 2000)
        XCTAssertThrowsError(try sut.updateRange(clip.id!, inMs: 100, outMs: 50))
    }

    func test_deleteClip_removesRow() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try sut.deleteClip(clip.id!)
        XCTAssertNil(try sut.fetchClip(clip.id!))
    }

    func test_fetchClips_forSourceReturnsInOrder() throws {
        _ = try sut.saveRange(sourceID: sourceID, inMs: 5000, outMs: 6000)
        _ = try sut.saveRange(sourceID: sourceID, inMs: 1000, outMs: 2000)
        _ = try sut.saveRange(sourceID: sourceID, inMs: 3000, outMs: 4000)
        let clips = try sut.fetchClips(forSource: sourceID)
        XCTAssertEqual(clips.map(\.inMs), [1000, 3000, 5000])
    }

    func test_incrementUsed_bumpsCounter() throws {
        let clip = try sut.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try sut.incrementUsed(clip.id!)
        try sut.incrementUsed(clip.id!)
        let reloaded = try sut.fetchClip(clip.id!)
        XCTAssertEqual(reloaded?.usedCount, 2)
    }
}
