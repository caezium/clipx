import XCTest
import AVFoundation
import GRDB
@testable import Clipx

/// Opt-in checks driven by Scripts/verify-integrations.py. Ordinary suites skip
/// these rather than contacting an existing server or downloading a schema.
#if DIRECT_BUILD
final class ExternalIntegrationTests: XCTestCase {
    @MainActor
    func testStintRenderUploadShareAndCommentRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["CLIPX_STINT_TEST_URL"] else {
            throw XCTSkip("Requires the disposable Stint server from verify-integrations.py")
        }
        let base = try XCTUnwrap(URL(string: address))
        XCTAssertEqual(base.scheme, "http")
        XCTAssertEqual(base.host, "127.0.0.1")
        guard base.scheme == "http", base.host == "127.0.0.1" else { return }
        let evidence = try evidenceDirectory()
        let sourceURL = evidence.appendingPathComponent("source.mp4")
        try MediaRegressionTests.requireFFmpeg()
        try MediaRegressionTests.makeColorFixture(at: sourceURL)
        let database = try Database.inMemory()
        var source = MediaRegressionTests.source(path: sourceURL.path)
        var clip = Clip(id: 1, sourceID: 1, name: "Integration selection", inMs: 2000, outMs: 4000,
                        notes: "Keep my personal notes", createdAt: 0)
        try database.write { db in
            try source.insert(db)
            try clip.insert(db)
        }

        // Use the production renderer and HTTP client, including multipart upload.
        let link = try await StintBridge.transfer(
            clipIDs: [1], projectName: "Clipx disposable verification",
            config: .init(baseURL: base), database: database
        )
        let saved = try XCTUnwrap(database.read { try Clip.fetchOne($0, key: 1) })
        let projectID = try XCTUnwrap(saved.stintProjectId)
        let remoteID = try XCTUnwrap(saved.stintClipId)
        XCTAssertEqual(saved.reviewUrl, link.absoluteString)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT uploaded FROM stint_transfer_items") }, 1)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT completed FROM stint_transfer_batches") }, 1)

        let token = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "t" })?.value)
        let guest = URLSession(configuration: .ephemeral)
        defer { guest.invalidateAndCancel() }
        _ = try await request(guest, base: base, path: "api/projects/\(projectID)/claim",
                              body: ["token": token])
        let video = try await request(guest, base: base, path: "api/clips/\(remoteID)/video")
        XCTAssertGreaterThan(video.count, 1000)
        let downloaded = evidence.appendingPathComponent("stint-downloaded.mp4")
        try video.write(to: downloaded)
        let duration = try await AVURLAsset(url: downloaded).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)

        struct CommentResponse: Decodable {
            struct Comment: Decodable { let id: String }
            let comment: Comment
        }
        let commentData = try await request(guest, base: base, path: "api/clips/\(remoteID)/comments",
                                            body: ["body": "Keep this moment", "authorName": "Fixture reviewer", "t": 0.5])
        let commentID = try JSONDecoder().decode(CommentResponse.self, from: commentData).comment.id
        _ = try await request(guest, base: base, path: "api/clips/\(remoteID)/comments",
                              body: ["body": "Agreed on this selection", "authorName": "Fixture reviewer", "parentCommentId": commentID])
        await StintBridge.refreshComments(clipIDs: [1], database: database)
        let updated = try XCTUnwrap(database.read { try Clip.fetchOne($0, key: 1) })
        let notes = try XCTUnwrap(updated.notes)
        XCTAssertTrue(notes.contains("Keep my personal notes"))
        XCTAssertTrue(notes.contains("Keep this moment"))
        XCTAssertTrue(notes.contains("Agreed on this selection"))
        try notes.write(to: evidence.appendingPathComponent("stint-returned-notes.txt"), atomically: true, encoding: .utf8)
        print("STINT_INTEGRATION: production render/upload, guest media access, threaded comment pull-back, local receipts")
    }

    func testGeneratedFCPXMLAgainstAppleDTD() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPX_FCPXML_DTD_PATH"] else {
            throw XCTSkip("Requires Apple's DTD from verify-integrations.py")
        }
        let evidence = try evidenceDirectory()
        var silent = MediaRegressionTests.source(path: "/tmp/silent & special#name.mov")
        silent.audioChannels = 0
        var fractional = MediaRegressionTests.source(path: "/tmp/fractional.mov")
        fractional.fps = 23.976
        let a = Clip(id: 1, sourceID: 1, name: "One frame & \"quote\"\u{1}", inMs: 33, outMs: 67, createdAt: 0)
        let b = Clip(id: 2, sourceID: 1, inMs: 42, outMs: 1043, createdAt: 0)
        let cases: [(String, [(clip: Clip, source: Source)])] = [
            ("silent-one-frame", [(a, silent)]),
            ("mixed-rates-and-audio", [(a, silent), (b, fractional), (a, silent)])
        ]
        for (name, items) in cases {
            let output = evidence.appendingPathComponent(name + ".fcpxml")
            try FCPXMLWriter.buildDocument(items: items).write(to: output, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
            process.arguments = ["--nonet", "--noout", "--dtdvalid", path, output.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(name): \(message)")
        }
        print("FCPXML_DTD_INTEGRATION: 2 production documents validated against Apple's full 1.10 DTD")
    }

    private func evidenceDirectory() throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["CLIPX_INTEGRATION_EVIDENCE"])
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func request(_ session: URLSession, base: URL, path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 30)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "clipx.integration", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "\(path) returned HTTP \(http.statusCode)"])
        }
        return data
    }
}
#endif
