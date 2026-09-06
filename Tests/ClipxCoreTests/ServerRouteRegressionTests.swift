import XCTest
import GRDB
@testable import Clipx

@MainActor
final class ServerRouteRegressionTests: XCTestCase {
    private func withContext(_ run: (ClipxRoutes.Context, String) async throws -> Void) async throws {
        let suite = "com.clipx.server-regression.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = PairingStore(defaults: defaults)
        let token = try XCTUnwrap(pairing.authenticate(pin: pairing.pin))
        let database = try Database.inMemory()
        let markerStore = MarkerStore(database: database, didChange: {})
        try await run(ClipxRoutes.Context(database: database, markerStore: markerStore, pairingStore: pairing), token)
    }

    private func request(_ path: String, token: String, method: String = "GET", query: [String: String] = [:], body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: query,
                    headers: ["host": "localhost:7878", "authorization": "Bearer \(token)"], body: body)
    }

    func test_pairingAndHostGatesRunBeforeLibraryRoutes() async throws {
        try await withContext { context, token in
            let unauthorized = await ClipxRoutes.handle(request("/api/sources", token: "wrong"), context: context)
            XCTAssertEqual(unauthorized.status, 401)
            let invalidHost = HTTPRequest(method: "GET", path: "/api/sources", query: [:],
                headers: ["host": "evil.example", "authorization": "Bearer \(token)"], body: Data())
            let forbidden = await ClipxRoutes.handle(invalidHost, context: context)
            XCTAssertEqual(forbidden.status, 403)
            context.pairingStore.rotate()
            let revoked = await ClipxRoutes.handle(request("/api/sources", token: token), context: context)
            XCTAssertEqual(revoked.status, 401)
        }
    }

    func test_pairedClipWritesValidateAllSourceTimeBounds() async throws {
        try await withContext { context, token in
            let db = try XCTUnwrap(context.database)
            try db.write { db in
                try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at,duration_ms) VALUES(1,'/isolated.mov','abc123',0,0,10000)")
            }
            for marks: [Int64] in [[-1, 100], [0, 10001], [.min, .max], [100, 100]] {
                let body = try JSONSerialization.data(withJSONObject: ["inMs": marks[0], "outMs": marks[1]])
                let response = await ClipxRoutes.handle(request("/api/sources/1/clips", token: token, method: "POST", body: body), context: context)
                XCTAssertEqual(response.status, 400)
            }
            XCTAssertEqual(try db.read { try Clip.fetchCount($0) }, 0)
            let valid = try JSONSerialization.data(withJSONObject: ["inMs": 0, "outMs": 10000])
            let saved = await ClipxRoutes.handle(request("/api/sources/1/clips", token: token, method: "POST", body: valid), context: context)
            XCTAssertEqual(saved.status, 201)
            let missing = await ClipxRoutes.handle(request("/api/sources/999/clips", token: token, method: "POST", body: valid), context: context)
            XCTAssertEqual(missing.status, 404)
            XCTAssertEqual(try db.read { try Clip.fetchCount($0) }, 1)
        }
    }

    func test_paginationReachesSourcesAndClipsBeyondOldCapsAndReturnsTransforms() async throws {
        try await withContext { context, token in
            let database = try XCTUnwrap(context.database)
            try database.write { db in
                for id in 1...725 {
                    try db.execute(sql: "INSERT INTO sources(id,path,hash,mtime,imported_at,duration_ms,rotation,speed) VALUES(?,?,?,0,0,1000,90,2)", arguments: [id, "/source-\(id).mov", "hash-\(id)"])
                    try db.execute(sql: "INSERT INTO clips(source_id,in_ms,out_ms,created_at) VALUES(?,0,1000,0)", arguments: [id])
                }
            }
            for kind in ["sources", "clips"] {
                var ids = Set<Int64>()
                for offset in stride(from: 0, to: 800, by: 100) {
                    let response = await ClipxRoutes.handle(request("/api/\(kind)", token: token, query: ["limit": "100", "offset": "\(offset)"]), context: context)
                    XCTAssertEqual(response.status, 200)
                    let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
                    for row in rows {
                        ids.insert(try XCTUnwrap(row["id"] as? Int64))
                        if kind == "sources" {
                            XCTAssertEqual(row["rotation"] as? Int, 90)
                            XCTAssertEqual(row["speed"] as? Double, 2)
                        }
                    }
                }
                XCTAssertEqual(ids.count, 725, kind)
            }
        }
    }

    func test_fileResponsesStreamCorrectFullAndSuffixContentWithBoundedMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipx-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.bin")
        let bytes = Data((0..<2_500_000).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        for header in [nil, "bytes=0-2499999", "bytes=-500"] as [String?] {
            var headers: [String: String] = [:]
            if let header { headers["range"] = header }
            let req = HTTPRequest(method: "GET", path: "/fixture", query: [:], headers: headers, body: Data())
            let response = ClipxRoutes.serveFileWithRange(at: url, mime: "video/mp4", request: req)
            XCTAssertEqual(response.status, header == nil ? 200 : 206)
            XCTAssertTrue(response.body.isEmpty, "File bytes must not be buffered into a response")
            let file = try XCTUnwrap(response.fileBody)
            var received = Data()
            while file.remaining > 0 {
                let chunk = try file.readNextChunk()
                XCTAssertLessThanOrEqual(chunk.count, 65_536)
                received.append(chunk)
            }
            XCTAssertEqual(received, header == "bytes=-500" ? Data(bytes.suffix(500)) : bytes)
            let wire = try XCTUnwrap(String(data: response.serializeHead(), encoding: .utf8))
            XCTAssertTrue(wire.contains("Content-Length: \(received.count)\r\n"))
        }
        let req = HTTPRequest(method: "GET", path: "/fixture", query: [:], headers: ["range": "bytes=9223372036854775807-"], body: Data())
        XCTAssertEqual(ClipxRoutes.serveFileWithRange(at: url, mime: "video/mp4", request: req).status, 416)
    }
}
