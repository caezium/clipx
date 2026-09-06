import Foundation
import GRDB

/// API endpoints + static-asset serving for the embedded Clipx web UI.
/// Auth: PIN-based pairing. The two unauthenticated routes are the static
/// frontend (so the user can land on the page) and POST /api/pair.
/// Everything else requires `Authorization: Bearer <token>`.
@MainActor
enum ClipxRoutes {
    @MainActor
    struct Context {
        let database: Database?
        let markerStore: MarkerStore?
        let thumbnailEngine: ThumbnailEngine?
        let webProxyEngine: WebProxyEngine?
        let pairingStore: PairingStore

        init(database: Database? = nil, markerStore: MarkerStore? = nil,
             thumbnailEngine: ThumbnailEngine? = nil, webProxyEngine: WebProxyEngine? = nil,
             pairingStore: PairingStore) {
            self.database = database
            self.markerStore = markerStore
            self.thumbnailEngine = thumbnailEngine
            self.webProxyEngine = webProxyEngine
            self.pairingStore = pairingStore
        }

        static var live: Context {
            let env = AppEnvironment.shared
            return Context(database: env.database, markerStore: env.markerStore,
                thumbnailEngine: env.thumbnailEngine, webProxyEngine: env.webProxyEngine,
                pairingStore: .shared)
        }
    }

    static func handle(_ request: HTTPRequest, context suppliedContext: Context? = nil) async -> HTTPResponse {
        let context = suppliedContext ?? .live
        guard !Task.isCancelled else { return .plain("Server stopped", status: 503) }
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
            return await pair(request, context: context)
        default:
            break
        }

        // Authenticated routes from here down.
        guard authenticated(request, context: context) else {
            return HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"pair first"}"#.utf8)
            )
        }

        switch (request.method, request.path) {
        case ("GET", "/api/sources"):
            return await sources(request, context: context)
        case ("GET", "/api/clips"):
            return await clips(request, context: context)
        case ("GET", "/api/search"):
            return await search(request, context: context)
        default:
            break
        }

        if request.method == "GET", request.path.hasPrefix("/api/thumb/") {
            let hash = String(request.path.dropFirst("/api/thumb/".count))
                .replacingOccurrences(of: ".jpg", with: "")
            return await thumb(hash: hash, context: context)
        }
        if request.method == "GET", request.path.hasPrefix("/api/sprite/") {
            let hash = String(request.path.dropFirst("/api/sprite/".count))
                .replacingOccurrences(of: ".jpg", with: "")
            return await sprite(hash: hash, context: context)
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/clips") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/clips".count)
            if let id = Int64(middle) { return await clipsForSource(id: id, context: context) }
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/video") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/video".count)
            if let id = Int64(middle) { return await videoForSource(id: id, request: request, context: context) }
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/proxy-status") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/proxy-status".count)
            if let id = Int64(middle) { return await proxyStatus(id: id, context: context) }
        }
        if request.method == "POST", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/proxy-retry") {
            let middle = request.path.dropFirst("/api/sources/".count).dropLast("/proxy-retry".count)
            if let id = Int64(middle) { return await proxyStatus(id: id, context: context, retry: true) }
        }
        if request.method == "POST", request.path.hasPrefix("/api/clips/"),
           request.path.hasSuffix("/rating") {
            let middle = request.path
                .dropFirst("/api/clips/".count)
                .dropLast("/rating".count)
            if let id = Int64(middle) { return await setRating(clipID: id, request: request, context: context) }
        }
        if request.method == "POST", request.path.hasPrefix("/api/sources/"),
           request.path.hasSuffix("/clips") {
            let middle = request.path
                .dropFirst("/api/sources/".count)
                .dropLast("/clips".count)
            if let id = Int64(middle) { return await createClip(sourceID: id, request: request, context: context) }
        }
        if request.method == "GET", request.path.hasPrefix("/api/sources/"),
           let id = Int64(request.path.dropFirst("/api/sources/".count)) {
            guard let database = context.database else { return .serverError("Library not ready") }
            do {
                guard let source = try database.read({ try Source.fetchOne($0, key: id) }) else {
                    return .notFound("Source not found")
                }
                return .json(makeSourceDTO(source))
            } catch { return internalError(error, "source") }
        }

        return .notFound("No route for \(request.method) \(request.path)")
    }

    // MARK: - Auth

    private static func authenticated(_ request: HTTPRequest, context: Context) -> Bool {
        // Header path — the default for API requests.
        let header = request.headers["authorization"] ?? ""
        if header.lowercased().hasPrefix("bearer ") {
            let token = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if context.pairingStore.isValid(token: token) { return true }
        }
        // Same-origin session cookie — used by <video>/<img>/fetch so the
        // token never appears in the URL (where it leaks into logs/Referer). (#6)
        if let cookieTok = cookieValue(request.headers["cookie"], name: "clipx_session"),
           context.pairingStore.isValid(token: cookieTok) {
            return true
        }
        // Legacy query-string fallback — kept so already-paired clients that
        // still append ?token= keep working.
        if let qToken = request.query["token"],
           context.pairingStore.isValid(token: qToken) {
            return true
        }
        return false
    }

    private struct PairBody: Decodable { let pin: String }

    private static func pair(_ request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let body = request.decodeJSON(PairBody.self) else {
            return .badRequest("Expected {\"pin\": \"...\"}")
        }
        // Throttle brute force: once locked, refuse even a correct PIN. (#1)
        if context.pairingStore.isLockedOut() {
            return HTTPResponse(
                status: 429,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"too many attempts — locked, try again shortly"}"#.utf8)
            )
        }
        guard let token = context.pairingStore.authenticate(pin: body.pin) else {
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
        let rotation: Int
        let speed: Double
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

    private static func sources(_ request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let database = context.database else {
            return .serverError("Library not ready")
        }
        let limit = clampLimit(request.query["limit"])
        let offset = max(0, Int(request.query["offset"] ?? "0") ?? 0)
        do {
            let rows: [Source] = try database.read { db in
                try Source.fetchAll(
                    db,
                    sql: "SELECT * FROM sources ORDER BY COALESCE(created_at, imported_at) DESC, id DESC LIMIT ? OFFSET ?",
                    arguments: [limit, offset]
                )
            }
            return .json(rows.map(Self.makeSourceDTO))
        } catch {
            return internalError(error, "db")
        }
    }

    private static func clips(_ request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let database = context.database else {
            return .serverError("Library not ready")
        }
        let limit = clampLimit(request.query["limit"])
        let offset = max(0, Int(request.query["offset"] ?? "0") ?? 0)
        do {
            let dtos = try fetchClipDTOs(database: database, limit: limit, offset: offset, where: nil, args: [])
            return .json(dtos)
        } catch {
            return internalError(error, "db")
        }
    }

    private static func search(_ request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let database = context.database else {
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
        let limit = clampLimit(request.query["limit"], default: 100)
        let offset = max(0, Int(request.query["offset"] ?? "0") ?? 0)
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
                        ORDER BY COALESCE(created_at, imported_at) DESC, id DESC LIMIT ? OFFSET ?
                    """,
                    arguments: [needle, limit, offset]
                )
            }
            let clipDTOs = try fetchClipDTOs(
                database: database,
                limit: limit,
                offset: offset,
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

    private static func clipsForSource(id sourceID: Int64, context: Context) async -> HTTPResponse {
        guard let database = context.database,
              let markerStore = context.markerStore else {
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

    private static func thumb(hash: String, context: Context) async -> HTTPResponse {
        guard hash.range(of: "^[a-f0-9]{6,128}$", options: .regularExpression) != nil,
              let engine = context.thumbnailEngine else {
            return .badRequest("Invalid hash")
        }
        let url = engine.thumbPath(for: hash)
        guard let data = try? Data(contentsOf: url) else {
            return .notFound("Thumb not yet generated")
        }
        return .bytes(data, contentType: "image/jpeg")
    }

    /// Hashes whose hover-scrub sprite strip is being generated on demand right
    /// now. Lets `sprite(hash:)` dedupe the web client's retry polling instead
    /// of dispatching a fresh `generateSprite` — and a racing write to the same
    /// cache file — on every poll. MainActor-isolated: only touched by route
    /// dispatch and the (main-thread) generation completion below.
    private static var spritesInFlight: Set<String> = []

    /// Serves a source's hover-scrub sprite strip — the horizontal JPEG of 10
    /// frames `ThumbnailEngine.generateSprite` produces (240×135 per tile).
    /// Unlike single thumbs (pre-primed by `primeMissingThumbnails`), sprites
    /// are generated lazily on first hover: if the strip isn't cached we kick
    /// off generation and return 202 so the client retries, then serve the JPEG
    /// once it lands. `generateSprite` runs on the engine's real dispatch queue,
    /// so this call never blocks.
    private static func sprite(hash: String, context: Context) async -> HTTPResponse {
        guard hash.range(of: "^[a-f0-9]{6,128}$", options: .regularExpression) != nil,
              let engine = context.thumbnailEngine else {
            return .badRequest("Invalid hash")
        }
        let url = engine.spritePath(for: hash)
        if let data = try? Data(contentsOf: url) {
            return .bytes(data, contentType: "image/jpeg")
        }
        // Not cached yet. Kick off generation unless one's already running for
        // this hash — we need the source's file URL to extract frames.
        if !spritesInFlight.contains(hash) {
            guard let database = context.database else {
                return .serverError("Library not ready")
            }
            let source: Source? = try? database.read { db in
                try Source.filter(Source.Columns.hash == hash).fetchOne(db)
            }
            guard let source else { return .notFound("No source for hash") }
            guard FileManager.default.fileExists(atPath: source.path) else {
                return .notFound("Source file offline")
            }
            spritesInFlight.insert(hash)
            engine.generateSprite(source: source) { _ in
                // Fires on main (= MainActor). Clear the marker so a failed
                // generation can be retried on a later poll; a successful one
                // is served by the file-exists fast path above.
                Task { @MainActor in Self.spritesInFlight.remove(hash) }
            }
        }
        return HTTPResponse(
            status: 202,
            headers: ["Content-Type": "application/json", "Retry-After": "1"],
            body: Data(#"{"status":"generating"}"#.utf8)
        )
    }

    // Streams the compressed *proxy* with Range support so <video> can seek.
    // The raw source is tens of Mbps (DJI 1080p50) — unusable over Wi-Fi — so we
    // never serve it to the browser. If the proxy isn't transcoded yet we kick
    // it off and return 202; the web client polls /proxy-status and shows a
    // "Preparing…" overlay until it's ready.
    private static func videoForSource(id sourceID: Int64, request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let database = context.database,
              let proxy = context.webProxyEngine else {
            return .serverError("Library not ready")
        }
        guard let source: Source = try? database.read({ try Source.fetchOne($0, key: sourceID) }) else {
            return .notFound("Source #\(sourceID) not found")
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .notFound("Source file offline")
        }
        let state = await proxy.status(forHash: source.hash, rotation: source.rotation)
        guard state.ready else {
            await proxy.startProxyIfNeeded(sourcePath: source.path, hash: source.hash, rotation: source.rotation)
            let s = await proxy.status(forHash: source.hash, rotation: source.rotation)
            if let error = s.error { return .json(["error": error], status: 503) }
            let pct = Int((s.progress * 100).rounded())
            return HTTPResponse(
                status: 202,
                headers: ["Content-Type": "application/json", "Retry-After": "2"],
                body: Data("{\"status\":\"transcoding\",\"progress\":\(pct)}".utf8)
            )
        }
        return serveFileWithRange(
            at: proxy.proxyPath(forHash: source.hash, rotation: source.rotation),
            mime: "video/mp4",
            request: request
        )
    }

    /// {ready, progress} for a source's web proxy. Triggers transcoding on the
    /// first poll so the client doesn't have to hit /video to start the job.
    private static func proxyStatus(id sourceID: Int64, context: Context, retry: Bool = false) async -> HTTPResponse {
        guard let database = context.database,
              let proxy = context.webProxyEngine else {
            return .serverError("Library not ready")
        }
        guard let source: Source = try? database.read({ try Source.fetchOne($0, key: sourceID) }) else {
            return .notFound("Source #\(sourceID) not found")
        }
        struct Status: Encodable {
            let ready: Bool
            let progress: Int
            let offline: Bool
            let state: String
            let error: String?
        }
        if !FileManager.default.fileExists(atPath: source.path) {
            return .json(Status(ready: false, progress: 0, offline: true, state: "offline", error: nil))
        }
        await proxy.startProxyIfNeeded(sourcePath: source.path, hash: source.hash, rotation: source.rotation, retry: retry)
        let state = await proxy.status(forHash: source.hash, rotation: source.rotation)
        return .json(Status(ready: state.ready, progress: Int((state.progress * 100).rounded()),
                            offline: false, state: state.state, error: state.error))
    }

    /// Correct full / single-range HTTP responses are streamed by HTTPServer in
    /// bounded chunks. No Range means a complete 200 response, including empty files.
    static func serveFileWithRange(at url: URL, mime: String, request: HTTPRequest) -> HTTPResponse {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size >= 0 else {
            return .notFound("File not available")
        }
        let rangeHeader = request.headers["range"]
        if size == 0, rangeHeader == nil {
            return HTTPResponse(headers: ["Content-Type": mime, "Accept-Ranges": "bytes"])
        }
        guard let (start, end) = resolveByteRange(rangeHeader, size: size, maxChunk: .max) else {
            return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
        }
        do {
            var headers = ["Content-Type": mime, "Accept-Ranges": "bytes"]
            if rangeHeader != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
            var response = HTTPResponse(status: rangeHeader == nil ? 200 : 206, headers: headers)
            response.fileBody = try HTTPResponse.FileBody(url: url, offset: start, length: end - start + 1)
            return response
        } catch {
            return internalError(error, "file")
        }
    }

    private struct RatingBody: Decodable {
        let rating: Int
    }

    private static func setRating(clipID: Int64, request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let markerStore = context.markerStore else {
            return .serverError("Library not ready")
        }
        guard let body = request.decodeJSON(RatingBody.self) else {
            return .badRequest("Expected JSON {\"rating\": Int}")
        }
        guard (0...5).contains(body.rating) else { return .badRequest("Rating must be between 0 and 5") }
        do {
            guard try markerStore.fetchClip(clipID) != nil else { return .notFound("Clip not found") }
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
    private static func createClip(sourceID: Int64, request: HTTPRequest, context: Context) async -> HTTPResponse {
        guard let markerStore = context.markerStore else {
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
            return .json(ClipCreated(id: clip.id ?? -1, ok: true), status: 201)
        } catch MarkerError.invalidRange {
            return .badRequest("Choose a range within the source, with Out after In")
        } catch MarkerError.sourceNotFound {
            return .notFound("Source not found")
        } catch {
            return internalError(error, "create clip")
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
            online: src.online,
            rotation: VideoRotation.normalized(src.rotation),
            speed: src.speed.isFinite ? max(0.1, min(PlayerController.maxSpeed, src.speed)) : 1
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
        offset: Int = 0,
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
            sql += " ORDER BY c.created_at DESC, c.id DESC LIMIT ? OFFSET ?"
            var fullArgs = args
            fullArgs.append(limit)
            fullArgs.append(offset)
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
}
