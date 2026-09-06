import XCTest
import GRDB
@testable import Clipx

final class NativeMutationRegressionTests: XCTestCase {
    func test_totalSourceDurationIgnoresInvalidNegativesAndSaturatesOverflow() {
        XCTAssertEqual(FrameMath.totalDuration([1000, -5, 2000]), 3000)
        XCTAssertEqual(FrameMath.totalDuration([.max, .max, 1000]), .max)
    }
    private func fixture() throws -> (Clipx.Database, MarkerStore, Int64) {
        let database = try Database.inMemory()
        let sourceID = try database.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at,duration_ms) VALUES('/tmp/native.mov','native',0,1000,10000)")
            return db.lastInsertedRowID
        }
        return (database, MarkerStore(database: database, didChange: {}), sourceID)
    }

    func test_rangeValidationRejectsNegativeOverflowAndBeyondEOFWithoutWrites() throws {
        let (db, store, sourceID) = try fixture()
        let invalidRanges: [(Int64, Int64)] = [(-1, 100), (.min, .max), (0, 10001)]
        for (start, end) in invalidRanges {
            XCTAssertThrowsError(try store.saveRange(sourceID: sourceID, inMs: start, outMs: end))
        }
        XCTAssertThrowsError(try store.saveRange(sourceID: -1, inMs: 0, outMs: 1))
        XCTAssertEqual(try db.read { try Clip.fetchCount($0) }, 0)
        let clip = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 10000)
        XCTAssertThrowsError(try store.updateRange(clip.id!, inMs: 1, outMs: 10001))
        XCTAssertEqual(try store.fetchClip(clip.id!)?.outMs, 10000)
    }

    func test_captureIsAtomicAndPublishesOnlyAfterEveryRelationshipCommits() throws {
        let (db, _, sourceID) = try fixture()
        var revisions = 0
        let store = MarkerStore(database: db, didChange: { revisions += 1 })
        XCTAssertThrowsError(try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000,
                                                rating: 5, tags: ["good", " "], purposes: ["reel"]))
        XCTAssertEqual(try db.read { try Clip.fetchCount($0) }, 0)
        XCTAssertEqual(try db.read { try Tag.fetchCount($0) }, 0)
        XCTAssertEqual(revisions, 0)
        let clip = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000,
                                       rating: 4, tags: [" Good ", "good"], purposes: ["reel"])
        XCTAssertEqual(revisions, 1)
        XCTAssertEqual(clip.rating, 4)
        XCTAssertEqual(clip.purposeList, ["reel"])
        XCTAssertEqual(try TagStore(database: db).tags(forClip: clip.id!).map(\.name), ["good"])
    }

    func test_deleteUndoPreservesIdentityEveryFieldRelationshipsAndExportLink() throws {
        let (db, store, sourceID) = try fixture()
        let groupIDs = try db.write { db -> (Int64, Int64) in
            try db.execute(sql: "INSERT INTO projects(name,status,created_at) VALUES('Project','active',1)")
            let project = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO collections(name,created_at) VALUES('Collection',1)")
            return (project, db.lastInsertedRowID)
        }
        let clip = try store.saveRange(sourceID: sourceID, inMs: 100, outMs: 900,
                                       name: "Saved", rating: 5, tags: ["keep"], purposes: ["reel"],
                                       projectIDs: [groupIDs.0], collectionIDs: [groupIDs.1])
        try db.write { db in
            try db.execute(sql: "UPDATE clips SET color_label=2,mood='calm',shot_type='wide',camera_move='pan',setting='outdoor',notes='Personal',created_at=123,used_count=7,review_url='https://review/1',stint_clip_id='remote-clip',stint_project_id='remote-project',review_comment_count=3 WHERE id=?", arguments: [clip.id])
            try db.execute(sql: "INSERT INTO exports(clip_id,preset,exported_at,status) VALUES(?,'reels',2,'success')", arguments: [clip.id])
        }
        let before = try JSONEncoder().encode(XCTUnwrap(store.fetchClip(clip.id!)))
        let snapshots = try store.deleteClips([clip.id!])
        XCTAssertNil(try store.fetchClip(clip.id!))
        XCTAssertNil(try db.read { try Int64.fetchOne($0, sql: "SELECT clip_id FROM exports") })
        try store.restore(snapshots)
        let after = try JSONEncoder().encode(XCTUnwrap(store.fetchClip(clip.id!)))
        let beforeObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let afterObject = try JSONSerialization.jsonObject(with: after) as! NSDictionary
        XCTAssertEqual(beforeObject, afterObject)
        XCTAssertEqual(try TagStore(database: db).tags(forClip: clip.id!).map(\.name), ["keep"])
        XCTAssertEqual(try db.read { try Int64.fetchOne($0, sql: "SELECT project_id FROM clip_projects") }, groupIDs.0)
        XCTAssertEqual(try db.read { try Int64.fetchOne($0, sql: "SELECT collection_id FROM clip_collections") }, groupIDs.1)
        XCTAssertEqual(try db.read { try Int64.fetchOne($0, sql: "SELECT clip_id FROM exports") }, clip.id)
    }

    func test_structuredClearIsDistinctFromNoChange() throws {
        let (_, store, sourceID) = try fixture()
        let clip = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try store.updateStructured(clip.id!, shotType: .set("wide"), cameraMove: .set("pan"), setting: .set("outdoor"))
        try store.updateStructured(clip.id!, shotType: .set(nil))
        let changed = try XCTUnwrap(store.fetchClip(clip.id!))
        XCTAssertNil(changed.shotType)
        XCTAssertEqual(changed.cameraMove, "pan")
        XCTAssertEqual(changed.setting, "outdoor")
        try store.updateStructured(clip.id!, cameraMove: .set(nil), setting: .set(nil))
        XCTAssertNil(try store.fetchClip(clip.id!)?.cameraMove)
        XCTAssertNil(try store.fetchClip(clip.id!)?.setting)
    }

    @MainActor
    func test_inspectorDraftFlushesOnNavigationAndRetainsFailedWritesForRetry() throws {
        let (db, store, sourceID) = try fixture()
        let clip = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000, name: "Original")
        let drafts = InspectorDraftStore()
        drafts.record(clip: clip, name: "Without Enter", notes: "Typed just before navigation")
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_draft BEFORE UPDATE ON clips BEGIN SELECT RAISE(FAIL, 'disk unavailable'); END") }
        XCTAssertThrowsError(try drafts.flush(clip.id!, store: store))
        XCTAssertTrue(drafts.hasPendingChanges(clip.id!))
        XCTAssertEqual(drafts.draft(for: clip).name, "Without Enter")
        XCTAssertEqual(try store.fetchClip(clip.id!)?.name, "Original")
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_draft") }
        try drafts.flush(clip.id!, store: store)
        XCTAssertFalse(drafts.hasPendingChanges(clip.id!))
        XCTAssertEqual(try store.fetchClip(clip.id!)?.notes, "Typed just before navigation")
        XCTAssertEqual(try store.fetchClip(clip.id!)?.name, "Without Enter")
    }

    func test_tagAndTextWritesInvalidateOnlyCommittedSearchChanges() throws {
        let (db, _, sourceID) = try fixture()
        var revisions = 0
        let store = MarkerStore(database: db, didChange: { revisions += 1 })
        let tags = TagStore(database: db, didChange: { revisions += 1 })
        let search = SearchEngine(database: db)
        let clip = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        try tags.addTag("searchable", toClip: clip.id!)
        XCTAssertEqual(revisions, 2)
        XCTAssertEqual(try search.search(query: "searchable", filters: ClipFilters(), sort: .nameAsc).count, 1)
        try tags.removeTag("searchable", fromClip: clip.id!)
        XCTAssertEqual(revisions, 3)
        XCTAssertTrue(try search.search(query: "searchable", filters: ClipFilters(), sort: .nameAsc).isEmpty)
        try store.updateNotes(clip.id!, notes: "newneedle")
        XCTAssertEqual(revisions, 4)
        XCTAssertEqual(try search.search(query: "newneedle", filters: ClipFilters(), sort: .nameAsc).count, 1)
        XCTAssertThrowsError(try tags.addTag("", toClip: clip.id!))
        XCTAssertEqual(revisions, 4)
    }

    @MainActor
    func test_dirtyInspectorPreservesConcurrentReviewReplacementAndRemoval() throws {
        let (_, store, sourceID) = try fixture()
        let saved = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        let oldBlock = "<!-- clipx:review -->\nOld comment\n<!-- /clipx:review -->"
        let newBlock = "<!-- clipx:review -->\nNew comment\n<!-- /clipx:review -->"
        try store.updateNotes(saved.id!, notes: "Personal before\n\n" + oldBlock + "\n\nPersonal after")
        let baseline = try XCTUnwrap(store.fetchClip(saved.id!))
        let drafts = InspectorDraftStore()
        drafts.record(clip: baseline, name: "Coast detail", notes: "Edited before\n\n" + oldBlock + "\n\nEdited after")
        try store.updateNotes(saved.id!, notes: "Personal before\n\n" + newBlock + "\n\nPersonal after")
        let merged = try XCTUnwrap(drafts.flush(saved.id!, store: store))
        XCTAssertEqual(merged.name, "Coast detail")
        XCTAssertEqual(merged.notes, "Edited before\n\n" + newBlock + "\n\nEdited after")
        drafts.record(clip: merged, name: merged.name!, notes: "Another edit\n\n" + newBlock + "\n\nKeep this suffix")
        try store.updateNotes(saved.id!, notes: "Edited before\n\nEdited after")
        try drafts.flush(saved.id!, store: store)
        let removed = try XCTUnwrap(store.fetchClip(saved.id!))
        XCTAssertFalse(removed.notes!.contains("clipx:review"))
        XCTAssertTrue(removed.notes!.contains("Another edit"))
        XCTAssertTrue(removed.notes!.contains("Keep this suffix"))
        drafts.record(clip: removed, name: removed.name!, notes: "")
        try store.updateNotes(saved.id!, notes: (removed.notes ?? "") + "\n\n" + newBlock)
        try drafts.flush(saved.id!, store: store)
        XCTAssertEqual(try store.fetchClip(saved.id!)?.notes, newBlock)
    }
}
