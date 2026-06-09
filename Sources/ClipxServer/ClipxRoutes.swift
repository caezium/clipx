import Foundation
import GRDB

/// API endpoints + static-asset serving for the embedded Clipx web UI.
/// Auth: PIN-based pairing. The two unauthenticated routes are the static
/// frontend (so the user can land on the page) and POST /api/pair.
/// Everything else requires `Authorization: Bearer <token>`.
@MainActor
enum ClipxRoutes {
    static func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // DNS-rebinding defense: only serve requests whose Host header targets
        // this machine (localhost / LAN IP / *.local). An attacker page on
        // evil.com pointed at our IP still carries Host: evil.com. (#4)
        guard isAllowedHost(request.headers["host"]) else {
            return HTTPResponse(
                status: 403,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("Forbidden host".utf8)
            )
        }
        // CORS preflight always succeeds.
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204)
        }

        // Open routes: static frontend + pairing.
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
        case ("POST", "/api/pair"):
            return await pair(request)
        default:
            break
        }

        // Authenticated routes from here down.
        guard authenticated(request) else {
            return HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"pair first"}"#.utf8)
            )
        }

        switch (request.method, request.path) {
        case ("GET", "/api/sources"):
            return await sources(request)
        case ("GET", "/api/clips"):
            return await clips(request)
        case ("GET", "/api/search"):
            return await search(request)
        default:
            break
        }

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
            if let id = Int64(middle) { return await clipsForSource(id: id) }
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/video") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/video".count)
            if let id = Int64(middle) { return await videoForSource(id: id, request: request) }
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/proxy-status") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/proxy-status".count)
            if let id = Int64(middle) { return await proxyStatus(id: id) }
        }
        if request.method == "POST", request.path.hasPrefix("/api/clips/"),
           request.path.hasSuffix("/rating") {
            let middle = request.path
                .dropFirst("/api/clips/".count)
                .dropLast("/rating".count)
            if let id = Int64(middle) { return await setRating(clipID: id, request: request) }
        }
        if request.method == "POST", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/clips") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/clips".count)
            if let id = Int64(middle) { return await createClip(sourceID: id, request: request) }
        }

        return .notFound("No route for \(request.method) \(request.path)")
    }

    // MARK: - Auth

    private static func authenticated(_ request: HTTPRequest) -> Bool {
        // Header path — the default for API requests.
        let header = request.headers["authorization"] ?? ""
        if header.lowercased().hasPrefix("bearer ") {
            let token = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if PairingStore.shared.isValid(token: token) { return true }
        }
        // Same-origin session cookie — used by <video>/<img>/fetch so the
        // token never appears in the URL (where it leaks into logs/Referer). (#6)
        if let cookieTok = cookieValue(request.headers["cookie"], name: "clipx_session"),
           PairingStore.shared.isValid(token: cookieTok) {
            return true
        }
        // Legacy query-string fallback — kept so already-paired clients that
        // still append ?token= keep working.
        if let qToken = request.query["token"],
           PairingStore.shared.isValid(token: qToken) {
            return true
        }
        return false
    }

    private struct PairBody: Decodable { let pin: String }

    private static func pair(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.decodeJSON(PairBody.self) else {
            return .badRequest("Expected {\"pin\": \"...\"}")
        }
        // Throttle brute force: once locked, refuse even a correct PIN. (#1)
        if PairingStore.shared.isLockedOut() {
            return HTTPResponse(
                status: 429,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"too many attempts — locked, try again shortly"}"#.utf8)
            )
        }
        guard let token = PairingStore.shared.authenticate(pin: body.pin) else {
            return HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"wrong PIN"}"#.utf8)
            )
        }
        return .json(["token": token])
    }

    // MARK: - Endpoint DTOs

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

    // MARK: - Endpoints

    private static func sources(_ request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database else {
            return .serverError("Library not ready")
        }
        let limit = clampLimit(request.query["limit"])
        do {
            let rows: [Source] = try database.read { db in
                try Source.fetchAll(
                    db,
                    sql: "SELECT * FROM sources ORDER BY COALESCE(created_at, imported_at) DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return .json(rows.map(Self.makeSourceDTO))
        } catch {
            return internalError(error, "db")
        }
    }

    private static func clips(_ request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database else {
            return .serverError("Library not ready")
        }
        let limit = clampLimit(request.query["limit"])
        do {
            let dtos = try fetchClipDTOs(database: database, limit: limit, where: nil, args: [])
            return .json(dtos)
        } catch {
            return internalError(error, "db")
        }
    }

    private static func search(_ request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database else {
            return .serverError("Library not ready")
        }
        let q = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        struct SearchResult: Encodable {
            let sources: [SourceDTO]
            let clips: [ClipDTO]
        }
        guard !q.isEmpty else {
            return .json(SearchResult(sources: [], clips: []))
        }
        // Simple substring match — full FTS5 is overkill for the web search
        // box and would need the user to learn syntax.
        let needle = "%\(sqlLikeEscape(q.lowercased()))%"
        do {
            let sourceRows: [Source] = try database.read { db in
                try Source.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM sources
                        WHERE LOWER(path) LIKE ? ESCAPE '\\'
                        ORDER BY COALESCE(created_at, imported_at) DESC LIMIT 50
                    """,
                    arguments: [needle]
                )
            }
            let clipDTOs = try fetchClipDTOs(
                database: database,
                limit: 50,
                where: "(LOWER(c.name) LIKE ? ESCAPE '\\' OR LOWER(c.notes) LIKE ? ESCAPE '\\')",
                args: [needle, needle]
            )
            return .json(SearchResult(
                sources: sourceRows.map(Self.makeSourceDTO),
                clips: clipDTOs
            ))
        } catch {
            return internalError(error, "search")
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
            let dtos = clips.map { Self.makeClipDTO(clip: $0, source: source) }
            return .json(dtos)
        } catch {
            return internalError(error, "db")
        }
    }

    private static func thumb(hash: String) async -> HTTPResponse {
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

    // Streams the compressed *proxy* with Range support so <video> can seek.
    // The raw source is tens of Mbps (DJI 1080p50) — unusable over Wi-Fi — so we
    // never serve it to the browser. If the proxy isn't transcoded yet we kick
    // it off and return 202; the web client polls /proxy-status and shows a
    // "Preparing…" overlay until it's ready.
    private static func videoForSource(id sourceID: Int64, request: HTTPRequest) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database,
              let proxy = AppEnvironment.shared.webProxyEngine else {
            return .serverError("Library not ready")
        }
        guard let source: Source = try? database.read({ try Source.fetchOne($0, key: sourceID) }) else {
            return .notFound("Source #\(sourceID) not found")
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .notFound("Source file offline")
        }
        let state = await proxy.status(forHash: source.hash)
        guard state.ready else {
            await proxy.startProxyIfNeeded(sourcePath: source.path, hash: source.hash)
            let s = await proxy.status(forHash: source.hash)
            let pct = Int((s.progress * 100).rounded())
            return HTTPResponse(
                status: 202,
                headers: ["Content-Type": "application/json", "Retry-After": "2"],
                body: Data("{\"status\":\"transcoding\",\"progress\":\(pct)}".utf8)
            )
        }
        return serveFileWithRange(
            at: proxy.proxyPath(forHash: source.hash),
            mime: "video/mp4",
            request: request
        )
    }

    /// {ready, progress} for a source's web proxy. Triggers transcoding on the
    /// first poll so the client doesn't have to hit /video to start the job.
    private static func proxyStatus(id sourceID: Int64) async -> HTTPResponse {
        guard let database = AppEnvironment.shared.database,
              let proxy = AppEnvironment.shared.webProxyEngine else {
            return .serverError("Library not ready")
        }
        guard let source: Source = try? database.read({ try Source.fetchOne($0, key: sourceID) }) else {
            return .notFound("Source #\(sourceID) not found")
        }
        struct Status: Encodable { let ready: Bool; let progress: Int; let offline: Bool }
        if !FileManager.default.fileExists(atPath: source.path) {
            return .json(Status(ready: false, progress: 0, offline: true))
        }
        let state = await proxy.status(forHash: source.hash)
        if !state.ready {
            await proxy.startProxyIfNeeded(sourcePath: source.path, hash: source.hash)
        }
        return .json(Status(ready: state.ready, progress: Int((state.progress * 100).rounded()), offline: false))
    }

    /// Serves any on-disk file with HTTP Range support. Always responds with a
    /// bounded chunk (≤1 MiB) — even when the client sends no Range header — so
    /// one request can never read a whole multi-hundred-MB file into memory. (#5)
    private static func serveFileWithRange(at url: URL, mime: String, request: HTTPRequest) -> HTTPResponse {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else {
            return .notFound("File not available")
        }
        guard let (start, end) = resolveByteRange(request.headers["range"], size: size) else {
            return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: Int(end - start + 1)) ?? Data()
            return HTTPResponse(
                status: 206,
                headers: [
                    "Content-Type": mime,
                    "Content-Range": "bytes \(start)-\(end)/\(size)",
                    "Accept-Ranges": "bytes",
                ],
                body: data
            )
        } catch {
            return internalError(error, "file")
        }
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
            return internalError(error, "update")
        }
    }

    private struct CreateClipBody: Decodable {
        let inMs: Int64
        let outMs: Int64
        let name: String?
    }

    /// Mark a new clip from the phone. Doesn't drive the Mac player — just
    /// records the range against the source so it shows up in both UIs.
    private static func createClip(sourceID: Int64, request: HTTPRequest) async -> HTTPResponse {
        guard let markerStore = AppEnvironment.shared.markerStore else {
            return .serverError("Library not ready")
        }
        guard let body = request.decodeJSON(CreateClipBody.self) else {
            return .badRequest("Expected {inMs, outMs, name?}")
        }
        do {
            let clip = try markerStore.saveRange(
                sourceID: sourceID,
                inMs: body.inMs,
                outMs: body.outMs,
                name: body.name
            )
            struct ClipCreated: Encodable {
                let id: Int64
                let ok: Bool
            }
            return .json(ClipCreated(id: clip.id ?? -1, ok: true))
        } catch {
            return .badRequest(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func makeSourceDTO(_ src: Source) -> SourceDTO {
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

    private static func makeClipDTO(clip: Clip, source: Source) -> ClipDTO {
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

    private static func fetchClipDTOs(
        database: Database,
        limit: Int,
        where: String?,
        args: [DatabaseValueConvertible]
    ) throws -> [ClipDTO] {
        try database.read { db -> [ClipDTO] in
            var sql = """
                SELECT c.*, s.path AS s_path, s.hash AS s_hash
                FROM clips c
                JOIN sources s ON s.id = c.source_id
            """
            if let whereClause = `where` {
                sql += " WHERE \(whereClause)"
            }
            sql += " ORDER BY c.created_at DESC LIMIT ?"
            var fullArgs = args
            fullArgs.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(fullArgs))
            return rows.compactMap { row in
                guard let clip = try? Clip(row: row) else { return nil }
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
                return makeClipDTO(clip: clip, source: source)
            }
        }
    }

    /// Logs the real error server-side and returns a generic message to the
    /// client. Raw `error.localizedDescription` can expose SQL, file paths, and
    /// schema details to anyone on the network. (#9)
    private static func internalError(_ error: Error, _ context: String) -> HTTPResponse {
        ClipxLog.app.error("web route \(context, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return .serverError("Internal server error")
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "mkv":        return "video/x-matroska"
        case "webm":       return "video/webm"
        case "avi":        return "video/x-msvideo"
        default:           return "application/octet-stream"
        }
    }
}
