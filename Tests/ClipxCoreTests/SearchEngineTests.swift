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
}
