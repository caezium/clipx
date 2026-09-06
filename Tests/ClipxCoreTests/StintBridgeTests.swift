import XCTest
@testable import Clipx

/// Covers the pure request-construction of the Clipx → Stint bridge. The live
/// HTTP round-trip is validated against a running Stint server, not here.
final class StintBridgeTests: XCTestCase {
    private let base = URL(string: "http://stint.local:4040")!

    func test_shareURL_matchesStintRouteAndTokenAuth() {
        let url = StintBridge.shareURL(base: base, projectID: "abc123", shareToken: "tok_XYZ")
        XCTAssertEqual(url.absoluteString, "http://stint.local:4040/p/abc123?t=tok_XYZ")
    }

    func test_ownerCookieHeader_format() {
        XCTAssertEqual(
            StintBridge.ownerCookieHeader(projectID: "p1", ownerKey: "ownerKEY"),
            "owner_p1=ownerKEY"
        )
    }

    func test_multipartVideoBody_containsBoundaryFieldsAndFileBytes() {
        let fileBytes = Data([0x00, 0x01, 0x02, 0xFF])
        let body = StintBridge.multipartVideoBody(
            fieldName: "video",
            filename: "clip.mp4",
            mimeType: "video/mp4",
            fileData: fileBytes,
            extraFields: ["durationSeconds": "8.500"],
            boundary: "BOUND"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BOUND\r\n"))
        XCTAssertTrue(text.contains("name=\"durationSeconds\""))
        XCTAssertTrue(text.contains("8.500"))
        XCTAssertTrue(text.contains("name=\"video\"; filename=\"clip.mp4\""))
        XCTAssertTrue(text.contains("Content-Type: video/mp4"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        // The raw file bytes survive intact inside the body.
        XCTAssertTrue(body.range(of: fileBytes) != nil)
    }

    func test_formatComments_threadsAndCounts() {
        let comments = [
            StintBridge.StintComment(id: "a", t: 42, authorName: "Coach", body: "brake later into T3", resolved: false, parentCommentId: nil, transcript: nil),
            StintBridge.StintComment(id: "b", t: nil, authorName: "Henry", body: "got it", resolved: false, parentCommentId: "a", transcript: nil),
            StintBridge.StintComment(id: "c", t: 70, authorName: "Coach", body: "", resolved: true, parentCommentId: nil, transcript: "nice apex"),
        ]
        let result = StintBridge.formatComments(comments)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.text.contains("[0:42] Coach: brake later into T3"))
        XCTAssertTrue(result.text.contains("reply Henry: got it"))
        XCTAssertTrue(result.text.contains("[1:10] Coach (resolved): [voice] nice apex"))
    }

    func test_mergeReviewNotes_replacesPriorBlock() {
        let user = "my own note"
        let first = StintBridge.mergeReviewNotes(existing: user, digest: "- one")
        XCTAssertTrue(first.hasPrefix("my own note"))
        XCTAssertTrue(first.contains("- one"))
        // A second refresh replaces the review block, not stacks it.
        let second = StintBridge.mergeReviewNotes(existing: first, digest: "- two")
        XCTAssertTrue(second.contains("- two"))
        XCTAssertFalse(second.contains("- one"))
        XCTAssertTrue(second.hasPrefix("my own note"))
        // Exactly one review marker remains.
        XCTAssertEqual(second.components(separatedBy: "<!-- clipx:review -->").count, 2)
    }

    func test_config_isNilWhenURLUnset() {
        let key = "stintServerURL"
        let saved = AppPreferences.defaults.string(forKey: key)
        defer { AppPreferences.defaults.set(saved, forKey: key) }

        AppPreferences.defaults.set("", forKey: key)
        XCTAssertNil(StintBridge.Config.current)

        AppPreferences.defaults.set("not a url", forKey: key)
        XCTAssertNil(StintBridge.Config.current)

        AppPreferences.defaults.set("http://stint.local:4040", forKey: key)
        XCTAssertEqual(StintBridge.Config.current?.baseURL.absoluteString, "http://stint.local:4040")
    }
}

@MainActor
final class StintTransferRegressionTests: XCTestCase {
    private final class FakeClient {
        var projects = 0
        var clips = 0
        var uploads = 0
        var failSecondUpload = true
    }

    func testPartialFailurePersistsIdentityAndRetrySkipsCompletedUploads() async throws {
        let database = try Database.inMemory()
        try database.write { db in
            try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at,duration_ms) VALUES(1,'/fixture','fixture',0,0,8000)")
            for id in 1...2 {
                try db.execute(sql: "INSERT INTO clips(id,source_id,in_ms,out_ms,created_at) VALUES(?,1,0,1000,0)", arguments: [id])
            }
        }
        let folder = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeClient()
        let client = StintBridge.Client(
            createProject: { _, _ in
                fake.projects += 1
                return StintBridge.CreatedProject(project: .init(id: "project-1"), ownerKey: "owner", shareToken: "share")
            },
            createClip: { _, _, _, _ in
                fake.clips += 1
                return "remote-\(fake.clips)"
            },
            uploadVideo: { _, _, _, _, _, _ in
                fake.uploads += 1
                if fake.uploads == 2 && fake.failSecondUpload { throw StintBridge.StintError.http(503) }
            }
        )
        let config = StintBridge.Config(baseURL: URL(string: "https://stint.invalid")!)
        let renderer: (Int64) async throws -> StintBridge.RenderedClip = { id in
            let file = folder.appendingPathComponent("clip-\(id).mp4")
            try Data([1]).write(to: file)
            return .init(fileURL: file, durationSeconds: 1, name: "Clip \(id)")
        }
        do {
            _ = try await StintBridge.transfer(clipIDs: [1, 2], projectName: "Review", config: config,
                                              database: database, client: client, render: renderer)
            XCTFail("Second upload should fail")
        } catch StintBridge.StintError.http(503) { }
        XCTAssertEqual(fake.projects, 1)
        XCTAssertEqual(fake.clips, 2)
        let statuses = try database.read { try Int.fetchAll($0, sql: "SELECT uploaded FROM stint_transfer_items ORDER BY clip_id") }
        XCTAssertEqual(statuses, [1, 0])
        XCTAssertEqual(try database.read { try Clip.fetchOne($0, key: 1)?.stintClipId }, "remote-1")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Failed upload must clean its render")
        fake.failSecondUpload = false
        let link = try await StintBridge.transfer(clipIDs: [2, 1], projectName: "Review", config: config,
                                                  database: database, client: client, render: renderer)
        XCTAssertEqual(link.absoluteString, "https://stint.invalid/p/project-1?t=share")
        XCTAssertEqual(fake.projects, 1, "Retry reuses saved project")
        XCTAssertEqual(fake.clips, 2, "Retry reuses the remote clip created before upload failure")
        XCTAssertEqual(fake.uploads, 3, "Completed first upload is skipped")
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT completed FROM stint_transfer_batches") }, 1)
        XCTAssertEqual(try database.read { try Clip.fetchOne($0, key: 2)?.stintClipId }, "remote-2")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testBoundedReviewRefreshPreservesTrailingNotesAndClearsEmptyDigest() {
        let first = StintBridge.mergeReviewNotes(existing: "Before", digest: "- Old comment") + "\n\nPersonal paragraph after review"
        let refreshed = StintBridge.mergeReviewNotes(existing: first, digest: "- New comment")
        XCTAssertTrue(refreshed.hasSuffix("Personal paragraph after review"))
        XCTAssertFalse(refreshed.contains("Old comment"))
        let empty = StintBridge.mergeReviewNotes(existing: refreshed, digest: "")
        XCTAssertFalse(empty.contains("New comment"))
        XCTAssertTrue(empty.contains("Before"))
        XCTAssertTrue(empty.contains("Personal paragraph after review"))
    }

    func testLegacyUnboundedReviewIsPreservedWithoutGuessingUserBoundary() {
        let old = "Before\n\n<!-- clipx:review -->\nReview comments:\n- Old comment\n\nMy later note"
        let updated = StintBridge.mergeReviewNotes(existing: old, digest: "- New comment")
        XCTAssertTrue(updated.contains("My later note"))
        XCTAssertTrue(updated.contains("<!-- clipx:review-legacy -->"))
        let twice = StintBridge.mergeReviewNotes(existing: updated, digest: "- Latest comment")
        XCTAssertFalse(twice.contains("New comment"))
        XCTAssertTrue(twice.contains("My later note"))
    }

    func testMultipartAllocationIsRemovedWhenSourceCannotBeRead() throws {
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        XCTAssertThrowsError(try StintBridge.writeMultipartVideoBodyFile(
            fieldName: "video", filename: "missing.mp4", mimeType: "video/mp4",
            videoFileURL: URL(fileURLWithPath: "/missing-\(UUID().uuidString)"), extraFields: [:], boundary: "test"
        ))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(after.subtracting(before).filter { $0.hasPrefix("clipx-upload-") }.isEmpty)
    }
}

@MainActor
final class StintCommentRefreshRegressionTests: XCTestCase {
    private actor ReplyGate {
        private(set) var waiting = false
        private var reply: CheckedContinuation<[StintBridge.StintComment], Never>?
        func suspend() async -> [StintBridge.StintComment] {
            waiting = true
            return await withCheckedContinuation { reply = $0 }
        }
        func release(_ comments: [StintBridge.StintComment]) { reply?.resume(returning: comments); reply = nil }
    }

    func testRelinkedClipRejectsCommentsFromPreviousReview() async throws {
        let database = try databaseWithReviews()
        let gate = ReplyGate()
        let refresh = Task {
            await StintBridge.refreshComments(clipIDs: [1], database: database) { _, _, _, _ in await gate.suspend() }
        }
        await waitForRequest(gate)
        try database.write { db in
            try db.execute(sql: "UPDATE clips SET stint_project_id='new-project',stint_clip_id='new-clip',notes='New review notes' WHERE id=1")
        }
        await gate.release([comment("Old review response")])
        await refresh.value
        let clip = try database.read { try Clip.fetchOne($0, key: 1) }
        XCTAssertEqual(clip?.notes, "New review notes")
        XCTAssertNil(clip?.reviewCommentCount)
    }

    func testOlderRefreshCannotOverwriteNewerResponse() async throws {
        let database = try databaseWithReviews()
        let gate = ReplyGate()
        let old = Task {
            await StintBridge.refreshComments(clipIDs: [1], database: database) { _, _, _, _ in await gate.suspend() }
        }
        await waitForRequest(gate)
        await StintBridge.refreshComments(clipIDs: [1], database: database) { _, _, _, _ in
            [self.comment("Newest response")]
        }
        await gate.release([comment("Older response")])
        await old.value
        let clip = try database.read { try Clip.fetchOne($0, key: 1) }
        XCTAssertTrue(clip?.notes?.contains("Newest response") == true)
        XCTAssertFalse(clip?.notes?.contains("Older response") == true)
        XCTAssertTrue(clip?.notes?.hasPrefix("Personal notes") == true)
        XCTAssertEqual(clip?.reviewCommentCount, 1)
    }

    func testPartialRefreshFailureStillPublishesCommittedNotes() async throws {
        let database = try databaseWithReviews()
        let revision = AppState.shared.libraryRevision
        var requests = 0
        await StintBridge.refreshComments(clipIDs: [1, 2], database: database) { _, _, _, _ in
            requests += 1
            if requests == 2 { throw StintBridge.StintError.http(503) }
            return [self.comment("Saved before the next request failed")]
        }
        let notes = try database.read { try String.fetchAll($0, sql: "SELECT notes FROM clips") }
        XCTAssertEqual(notes.filter { $0.contains("Saved before the next request failed") }.count, 1)
        XCTAssertGreaterThan(AppState.shared.libraryRevision, revision)
    }

    private func databaseWithReviews() throws -> Database {
        let database = try Database.inMemory()
        try database.write { db in
            try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at) VALUES(1,'/fixture','h',0,0)")
            try db.execute(sql: "INSERT INTO stint_projects(project_id,owner_key,share_token,base_url,created_at) VALUES('project','owner','share','https://stint.invalid',0)")
            for id in 1...2 {
                try db.execute(sql: "INSERT INTO clips(id,source_id,in_ms,out_ms,created_at,notes,stint_project_id,stint_clip_id) VALUES(?,1,0,1000,0,'Personal notes','project',?)",
                               arguments: [id, "remote-\(id)"])
            }
        }
        return database
    }

    private func comment(_ text: String) -> StintBridge.StintComment {
        .init(id: text, t: 1, authorName: "Reviewer", body: text, resolved: false, parentCommentId: nil, transcript: nil)
    }

    private func waitForRequest(_ gate: ReplyGate) async {
        for _ in 0..<200 {
            if await gate.waiting { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Comment request did not start")
    }
}
