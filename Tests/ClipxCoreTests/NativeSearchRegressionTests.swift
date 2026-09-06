import XCTest
import GRDB
@testable import Clipx

final class NativeSearchRegressionTests: XCTestCase {
    func test_externalContentIntegrityDetectsAndRepairsMissingIndex() throws {
        let db = try Database.inMemory()
        let sourceID = try addSource(db, path: "/indexed", recorded: 10, imported: 20, online: true)
        _ = try MarkerStore(database: db).saveRange(sourceID: sourceID, inMs: 0, outMs: 1000, name: "needle")
        let search = SearchEngine(database: db)
        XCTAssertTrue(search.isIndexHealthy())
        try db.write { try $0.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('delete-all')") }
        XCTAssertFalse(search.isIndexHealthy())
        search.verifyAndRepairIndex()
        XCTAssertTrue(search.isIndexHealthy())
        XCTAssertEqual(try search.search(query: "needle", filters: ClipFilters(), sort: .nameAsc).count, 1)
    }

    func test_sourceAndClipQueriesShareRecordedImportedAndAvailabilityFilters() throws {
        let db = try Database.inMemory()
        let newlyImported = try addSource(db, path: "/old-shoot-new-import", recorded: 100, imported: 9000, online: true)
        let oldImport = try addSource(db, path: "/new-shoot-old-import", recorded: 9000, imported: 100, online: true)
        let offline = try addSource(db, path: "/offline-new-import", recorded: 9000, imported: 9000, online: false)
        let store = MarkerStore(database: db, didChange: {})
        for sourceID in [newlyImported, oldImport, offline] {
            _ = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000)
        }
        let search = SearchEngine(database: db)
        var filters = ClipFilters()
        filters.dateFrom = Date(timeIntervalSince1970: 8000)
        filters.dateTo = Date(timeIntervalSince1970: 10000)
        filters.onlineOnly = true
        XCTAssertEqual(try search.searchSources(query: "", filters: filters, sort: .sourceDateDesc).compactMap(\.id), [oldImport])
        XCTAssertEqual(try search.search(query: "", filters: filters, sort: .sourceDateDesc).map(\.sourceID), [oldImport])
        filters.dateField = .imported
        XCTAssertEqual(try search.searchSources(query: "", filters: filters, sort: .importedDesc).compactMap(\.id), [newlyImported])
        XCTAssertEqual(try search.search(query: "", filters: filters, sort: .importedDesc).map(\.sourceID), [newlyImported])
    }

    func test_queryTokensCanCombineClipTextAndTagsWithoutDuplicateResults() throws {
        let db = try Database.inMemory()
        let sourceID = try addSource(db, path: "/tagged", recorded: 10, imported: 20, online: true)
        let store = MarkerStore(database: db, didChange: {})
        let tagged = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000,
                                         name: "Coast detail", tags: ["sunset", "sunset reel", "100% keeper"])
        _ = try store.saveRange(sourceID: sourceID, inMs: 0, outMs: 1000, name: "Coast detail")
        let search = SearchEngine(database: db)
        XCTAssertEqual(try search.search(query: "coast sunset", filters: ClipFilters(), sort: .nameAsc).compactMap(\.id), [tagged.id!])
        XCTAssertEqual(try search.search(query: "100%", filters: ClipFilters(), sort: .nameAsc).compactMap(\.id), [tagged.id!])
        XCTAssertEqual(try search.search(query: ":\"Coast detail\"", filters: ClipFilters(), sort: .nameAsc).count, 2)
    }

    func test_paginationReachesEveryClipAndDefaultSearchDoesNotSilentlyCap() throws {
        let db = try Database.inMemory()
        let source = try addSource(db, path: "/many", recorded: 100, imported: 200, online: true)
        try db.write { db in
            for i in 0..<1205 {
                try db.execute(sql: "INSERT INTO clips(source_id,in_ms,out_ms,name,created_at,purpose) VALUES(?,0,1000,?,1,'reel')",
                               arguments: [source, "Clip \(i)"])
            }
        }
        let search = SearchEngine(database: db)
        let first = try search.search(query: "", filters: ClipFilters(), sort: .ratingDesc, limit: 500)
        let second = try search.search(query: "", filters: ClipFilters(), sort: .ratingDesc, limit: 500, offset: 500)
        let third = try search.search(query: "", filters: ClipFilters(), sort: .ratingDesc, limit: 500, offset: 1000)
        XCTAssertEqual(first.count, 500)
        XCTAssertEqual(second.count, 500)
        XCTAssertEqual(third.count, 205)
        XCTAssertEqual(Set((first + second + third).compactMap(\.id)).count, 1205)
        XCTAssertEqual(try search.search(query: "", filters: ClipFilters(), sort: .ratingDesc).count, 1205)
    }

    @MainActor
    func test_scopeNavigationAndClearKeepQueryAndHeaderTogether() {
        let state = AppState.shared
        defer { state.clearFilters() }
        state.selectCollection(8)
        state.selectProject(9)
        XCTAssertNil(state.selectedCollectionID)
        XCTAssertEqual(state.activeFilters.collectionIDs, [])
        XCTAssertEqual(state.activeFilters.projectIDs, [9])
        state.selectCollection(10)
        XCTAssertNil(state.selectedProjectID)
        XCTAssertEqual(state.activeFilters.projectIDs, [])
        state.clearFilters()
        XCTAssertNil(state.selectedCollectionID)
        XCTAssertFalse(state.activeFilters.isActive)
    }

    @MainActor
    func test_expiredUndoReleasesCapturedSnapshotAndCannotRun() async throws {
        final class Snapshot { var invoked = false }
        let state = AppState.shared
        var snapshot: Snapshot? = Snapshot()
        weak var retained: Snapshot?
        retained = snapshot
        state.showToast("Disposable Undo regression", actionLabel: "Undo") { [snapshot = snapshot!] in
            snapshot.invoked = true
        }
        let id = try XCTUnwrap(state.toasts.last?.id)
        snapshot = nil
        XCTAssertNotNil(retained)
        try await Task.sleep(nanoseconds: 6_200_000_000)
        XCTAssertFalse(state.toasts.contains { $0.id == id })
        XCTAssertNil(retained, "Expired Undo must release its captured deletion snapshot")
        state.runToastAction(id)
    }

    func test_remotePortInputRejectsMalformedReservedAndOverflowValues() {
        for value in ["-1", "0", "80", "65536", "99999999999999999999", "not a port", ""] {
            XCTAssertNil(RemotePortInput.parse(value))
        }
        XCTAssertEqual(RemotePortInput.parse(" 7878 "), 7878)
        XCTAssertEqual(RemotePortInput.parse("65535"), 65535)
    }

    private func addSource(_ db: Clipx.Database, path: String, recorded: Int64, imported: Int64, online: Bool) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: "INSERT INTO sources(path,hash,mtime,created_at,imported_at,online,duration_ms) VALUES(?,?,0,?,?,?,1000)",
                           arguments: [path, path, recorded, imported, online])
            return db.lastInsertedRowID
        }
    }
}
