import XCTest
import GRDB
@testable import Clipx

/// Corruption recovery on open. (#24)
final class DatabaseRecoveryTests: XCTestCase {
    func test_openOrRecover_recoversFromCorruptFileAndPreservesIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipx-rec-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("clipx.sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: url)

        // Must not throw — recovers to a working, migrated database.
        let db = try Database.openOrRecover(at: url)
        let names: [String] = try db.read { c in
            try String.fetchAll(c, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(names.contains("clips"))

        // The corrupt file is preserved aside, never silently destroyed.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(entries.contains { $0.contains("corrupt") }, "expected a sidelined file in \(entries)")
    }
}
