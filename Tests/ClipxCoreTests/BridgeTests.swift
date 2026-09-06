import XCTest
@testable import Clipx

final class ObsidianWriterTests: XCTestCase {
    func test_obsidianTimecode_formatsHoursMinutesSeconds() {
        // Frame portion now correctly tracks sub-second milliseconds at the
        // given fps. At 65_500ms with the default 30fps, the 500ms remainder
        // produces 15 frames. Previously integer-truncated to 0 always.
        XCTAssertEqual(ObsidianWriter.formatTimecode(0), "00:00:00:00")
        XCTAssertEqual(ObsidianWriter.formatTimecode(65_500), "00:01:05:15")
        XCTAssertEqual(ObsidianWriter.formatTimecode(3_600_000), "01:00:00:00")
    }

    func test_obsidianTimecode_framesNonZeroWithFps() {
        // (ms % 1000) * fps / 1000 — previously this was integer-truncated to
        // 0. At 500ms past the second mark and 30fps, we expect 15 frames.
        XCTAssertEqual(ObsidianWriter.formatTimecode(500, fps: 30), "00:00:00:15")
    }

    func test_obsidianSanitize_stripsDotDot() {
        // Defense-in-depth alongside the path containment check.
        let result = ObsidianWriter.sanitize("../../etc/passwd")
        XCTAssertFalse(result.contains(".."))
        XCTAssertFalse(result.hasPrefix("."))
    }
}

final class SidecarIdentityTests: XCTestCase {
    func testSameNameAndRenamedClipsKeepSeparateUserNotes() throws {
        let database = try Database.inMemory()
        let vault = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: vault) }
        try database.write { db in
            try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at,duration_ms,fps) VALUES(1,'/fixture','fixture',0,0,8000,30)")
            for id in 1...2 {
                try db.execute(sql: "INSERT INTO clips(id,source_id,name,in_ms,out_ms,created_at) VALUES(?,1,'Same name',0,1000,0)", arguments: [id])
            }
        }
        XCTAssertEqual(try ObsidianWriter.writeSidecars(clipIDs: [1, 2], vaultPath: vault.path, database: database), 2)
        let first = vault.appendingPathComponent("Clipx/clip-1.md")
        let second = vault.appendingPathComponent("Clipx/clip-2.md")
        var text = try String(contentsOf: first, encoding: .utf8)
        text = text.replacingOccurrences(of: "## Notes", with: "My introduction\n\n## Notes")
        text = text.replacingOccurrences(of: "_Add notes here._", with: "Personal note\n\n## Linked ideas\nKeep this heading\n\n## Next steps\nKeep this too")
        try text.write(to: first, atomically: true, encoding: .utf8)
        try database.write { try $0.execute(sql: "UPDATE clips SET name = 'Renamed' WHERE id = 1") }
        try ObsidianWriter.writeSidecars(clipIDs: [1, 2], vaultPath: vault.path, database: database)
        let reexported = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(reexported.contains("Personal note"))
        XCTAssertTrue(reexported.contains("My introduction"))
        XCTAssertTrue(reexported.contains("## Linked ideas\nKeep this heading"))
        XCTAssertTrue(reexported.contains("## Next steps\nKeep this too"))
        XCTAssertFalse(try String(contentsOf: second, encoding: .utf8).contains("Personal note"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("Clipx").path).count, 2)
    }

    func testLegacyNotesPreserveUserSectionsAndTail() {
        let legacy = "---\nclip_id: 1\n---\n\n## Notes\nA note\n\n## Linked ideas\nUser content\n\n## Linked\n- Source: `/source`\n\nAfter the link"
        XCTAssertEqual(ObsidianWriter.documentClipID(legacy), 1)
        let notes = ObsidianWriter.readExistingUserBody(legacy)
        XCTAssertTrue(notes?.contains("## Linked ideas\nUser content") == true)
        XCTAssertTrue(notes?.hasSuffix("After the link") == true)
        XCTAssertFalse(notes?.contains("- Source:") == true)
    }
}
