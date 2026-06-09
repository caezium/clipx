import XCTest
@testable import Clipx

final class SearchEngineTests: XCTestCase {
    var db: Clipx.Database!
    var sut: SearchEngine!

    override func setUpWithError() throws {
        db = try Database.inMemory()
        sut = SearchEngine(database: db)
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO sources(path, hash, mtime, imported_at) VALUES('/tmp/a', 'h', 0, 0)
            """)
            let srcID = dbConn.lastInsertedRowID
            try dbConn.execute(sql: """
                INSERT INTO clips(source_id, in_ms, out_ms, name, mood, shot_type, rating, color_label, created_at)
                VALUES
                    (?, 0, 1000, 'walking slow', 'melancholic', 'close-up', 5, 1, 100),
                    (?, 1000, 2000, 'running fast', 'energetic', 'wide', 3, 2, 200),
                    (?, 2000, 3000, 'standing still', 'calm', 'close-up', 4, NULL, 300)
            """, arguments: [srcID, srcID, srcID])
        }
    }

    func test_escapeFTS_wrapsTokensAndAppendsStar() {
        let escaped = SearchEngine.escapeFTS("walking slow")
        XCTAssertEqual(escaped, "\"walking\"* \"slow\"*")
    }

    func test_escapeFTS_handlesDoubleQuotes() {
        let escaped = SearchEngine.escapeFTS("she said \"hi\"")
        XCTAssertTrue(escaped.contains("\"\"hi\"\""))
    }

    func test_search_findsByName() throws {
        let results = try sut.search(query: "walk", filters: ClipFilters(), sort: .dateImportedDesc)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "walking slow")
    }

    func test_search_combinesQueryAndRatingFilter() throws {
        var filters = ClipFilters()
        filters.minRating = 4
        let results = try sut.search(query: "", filters: filters, sort: .ratingDesc)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.rating, 5)
    }

    func test_search_filtersByShotType() throws {
        var filters = ClipFilters()
        filters.shotTypes = ["close-up"]
        let results = try sut.search(query: "", filters: filters, sort: .dateImportedDesc)
        XCTAssertEqual(results.count, 2)
    }

    func test_search_filtersByColorLabel() throws {
        var filters = ClipFilters()
        filters.colorLabels = [2]
        let results = try sut.search(query: "", filters: filters, sort: .dateImportedDesc)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.colorLabel, 2)
    }

    func test_search_filtersByMoodLike() throws {
        var filters = ClipFilters()
        filters.moods = ["melan"]
        let results = try sut.search(query: "", filters: filters, sort: .dateImportedDesc)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.mood, "melancholic")
    }

    func test_search_sortsByDurationDesc() throws {
        let results = try sut.search(query: "", filters: ClipFilters(), sort: .durationDesc)
        XCTAssertEqual(results.count, 3) // all same duration; just check no crash
        XCTAssertEqual(results.map(\.durationMs).reduce(0, +), 3000)
    }

    // #23 — "Newest (filmed)" must order by the source's recording date, not by
    // when the clip was marked.
    func test_filmedSort_ordersBySourceRecordingDateNotMarkerTime() throws {
        let db2 = try Database.inMemory()
        let s2 = SearchEngine(database: db2)
        try db2.write { c in
            try c.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at,created_at) VALUES('/a','ha',0,0,1000)")
            let a = c.lastInsertedRowID
            try c.execute(sql: "INSERT INTO sources(path,hash,mtime,imported_at,created_at) VALUES('/b','hb',0,0,2000)")
            let b = c.lastInsertedRowID
            // Clip from the EARLIER-filmed source A is marked LATER (created_at 9000);
            // clip from the LATER-filmed source B is marked EARLIER (created_at 100).
            try c.execute(sql: "INSERT INTO clips(source_id,in_ms,out_ms,name,created_at) VALUES(?,0,1000,'fromA',9000)", arguments: [a])
            try c.execute(sql: "INSERT INTO clips(source_id,in_ms,out_ms,name,created_at) VALUES(?,0,1000,'fromB',100)", arguments: [b])
        }
        let newest = try s2.search(query: "", filters: ClipFilters(), sort: .sourceDateDesc)
        XCTAssertEqual(newest.map(\.name), ["fromB", "fromA"],
                       "filmed-desc follows source date (B=2000 before A=1000), not marker time")
    }

    // #25 — a rebuild restores correct search results after the FTS index desyncs.
    func test_ftsRebuild_restoresSearchAfterDesync() throws {
        XCTAssertEqual(try sut.search(query: "walk", filters: ClipFilters(), sort: .nameAsc).count, 1)
        // Wipe the external-content index out-of-band to simulate a desync.
        try db.write { c in try c.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('delete-all')") }
        XCTAssertEqual(try sut.search(query: "walk", filters: ClipFilters(), sort: .nameAsc).count, 0,
                       "desynced index returns nothing")
        try sut.rebuildIndex()
        XCTAssertEqual(try sut.search(query: "walk", filters: ClipFilters(), sort: .nameAsc).count, 1,
                       "rebuild restores results")
        XCTAssertTrue(sut.isIndexHealthy())
    }
}
