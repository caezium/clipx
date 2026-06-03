import Foundation
import GRDB

/// API endpoints + static-asset serving for the embedded Clipx web UI.
/// Dispatches incoming HTTPRequest to one of the route handlers. All
/// responses are JSON except the root and thumbnail proxy.
@MainActor
enum ClipxRoutes {
    /// Top-level dispatch.
    static func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // CORS preflight — always succeed; the real auth gate is the pairing
        // code, not Origin.
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204)
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return .html(WebContent.indexHTML)
        case ("GET", "/app.css"):
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/css; charset=utf-8"],
                body: Data(WebContent.appCSS.utf8)
            )
        case ("GET", "/app.js"):
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/javascript; charset=utf-8"],
                body: Data(WebContent.appJS.utf8)
            )
        case ("GET", "/api/health"):
            return .json(["status": "ok", "app": "clipx"])
        case ("GET", "/api/sources"):
            return await sources(request)
        case ("GET", "/api/clips"):
            return await clips(request)
        default:
            break
        }

        // Path-parameter routes — handled with a tiny pattern match.
        if request.method == "GET", request.path.hasPrefix("/api/thumb/") {
            let hash = String(request.path.dropFirst("/api/thumb/".count))
                .replacingOccurrences(of: ".jpg", with: "")
            return await thumb(hash: hash)
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/clips") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/clips".count)
            if let id = Int64(middle) {
                return await clipsForSource(id: id)
            }
        }
        if request.method == "POST", request.path.hasPrefix("/api/clips/"),
           request.path.hasSuffix("/rating") {
            let middle = request.path
                .dropFirst("/api/clips/".count)
                .dropLast("/rating".count)
            if let id = Int64(middle) {
                return await setRating(clipID: id, request: request)
            }
        }

        return .notFound("No route for \(request.method) \(request.path)")
    }

    // MARK: - Endpoints

    private struct SourceDTO: Encodable {
        let id: Int64
        let name: String
        let durationMs: Int64?
        let width: Int?
        let height: Int?
        let fps: Double?
        let hash: String
        let createdAt: Int64?
        let importedAt: Int64
        let online: Bool
    }

    private struct ClipDTO: Encodable {
        let id: Int64
        let sourceID: Int64
        let sourceName: String
        let sourceHash: String
        let name: String?
        let inMs: Int64
        let outMs: Int64
        let durationMs: Int64
        let rating: Int
        let mood: String?
        let createdAt: Int64
    }

    private static func sources(_ request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database else {
            return .serverError("Library not ready")
        }
        let limit = Int(request.query["limit"] ?? "200") ?? 200
        do {
            let rows: [Source] = try database.read { db in
                try Source.fetchAll(
                    db,
                    sql: "SELECT * FROM sources ORDER BY COALESCE(created_at, imported_at) DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            let dtos = rows.map { src in
                SourceDTO(
                    id: src.id ?? 0,
                    name: src.displayName,
                    durationMs: src.durationMs,
                    width: src.width,
                    height: src.height,
                    fps: src.fps,
                    hash: src.hash,
                    createdAt: src.createdAt,
                    importedAt: src.importedAt,
                    online: src.online
                )
            }
            return .json(dtos)
        } catch {
            return .serverError("DB error: \(error.localizedDescription)")
        }
    }

    private static func clips(_ request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database else {
            return .serverError("Library not ready")
        }
        let limit = Int(request.query["limit"] ?? "200") ?? 200
        do {
            let clipsAndSources = try database.read { db -> [(Clip, Source)] in
                let pairs = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT c.*, s.path AS s_path, s.hash AS s_hash
                        FROM clips c
                        JOIN sources s ON s.id = c.source_id
                        ORDER BY c.created_at DESC
                        LIMIT ?
                    """,
                    arguments: [limit]
                )
                return pairs.compactMap { row in
                    guard let clip = try? Clip(row: row) else { return nil }
                    // Source path + hash are pulled out via SQL aliases.
                    let path: String = row["s_path"] ?? ""
                    let hash: String = row["s_hash"] ?? ""
                    var source = Source(
                        id: clip.sourceID, path: path, bookmark: nil,
                        hash: hash, mtime: 0, durationMs: nil,
                        width: nil, height: nil, fps: nil, codec: nil,
                        audioChannels: nil, colorSpace: nil, createdAt: nil,
                        importedAt: 0, thumbPath: nil, online: true, notes: nil
                    )
                    source.id = clip.sourceID
                    return (clip, source)
                }
            }
            let dtos = clipsAndSources.map { (clip, source) in
                ClipDTO(
                    id: clip.id ?? 0,
                    sourceID: clip.sourceID,
                    sourceName: source.displayName,
                    sourceHash: source.hash,
                    name: clip.name,
                    inMs: clip.inMs,
                    outMs: clip.outMs,
                    durationMs: clip.durationMs,
                    rating: clip.rating,
                    mood: clip.mood,
                    createdAt: clip.createdAt
                )
            }
            return .json(dtos)
        } catch {
            return .serverError("DB error: \(error.localizedDescription)")
        }
    }

    private static func clipsForSource(id sourceID: Int64) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database,
              let markerStore = AppEnvironment.shared.markerStore else {
            return .serverError("Library not ready")
        }
        do {
            let source: Source? = try database.read { try Source.fetchOne($0, key: sourceID) }
            guard let source else { return .notFound("Source #\(sourceID) not found") }
            let clips = try markerStore.fetchClips(forSource: sourceID)
            let dtos = clips.map { clip in
                ClipDTO(
                    id: clip.id ?? 0,
                    sourceID: clip.sourceID,
                    sourceName: source.displayName,
                    sourceHash: source.hash,
                    name: clip.name,
                    inMs: clip.inMs,
                    outMs: clip.outMs,
                    durationMs: clip.durationMs,
                    rating: clip.rating,
                    mood: clip.mood,
                    createdAt: clip.createdAt
                )
            }
            return .json(dtos)
        } catch {
            return .serverError("DB error: \(error.localizedDescription)")
        }
    }

    private static func thumb(hash: String) async -> HTTPResponse {
        // Reject hashes that aren't hex — defensive against path traversal,
        // since we concat hash into a file path.
        guard hash.range(of: "^[a-f0-9]{6,128}$", options: .regularExpression) != nil,
              let engine = AppEnvironment.shared.thumbnailEngine else {
            return .badRequest("Invalid hash")
        }
        let url = engine.thumbPath(for: hash)
        guard let data = try? Data(contentsOf: url) else {
            return .notFound("Thumb not yet generated")
        }
        return .bytes(data, contentType: "image/jpeg")
    }

    private struct RatingBody: Decodable {
        let rating: Int
    }

    private static func setRating(clipID: Int64, request: HTTPRequest) async -> HTTPResponse {
        guard let markerStore = AppEnvironment.shared.markerStore else {
            return .serverError("Library not ready")
        }
        guard let body = request.decodeJSON(RatingBody.self) else {
            return .badRequest("Expected JSON {\"rating\": Int}")
        }
        do {
            try markerStore.updateRating(clipID, rating: body.rating)
            return .json(["ok": true])
        } catch {
            return .serverError("Update failed: \(error.localizedDescription)")
        }
    }
}
