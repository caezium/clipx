import Foundation
import AppKit
import AVFoundation
import GRDB

/// Bridges a Clipx clip into a Stint review project — the review half of the
/// Clipx ⇄ Stint merge. It renders the clip, creates a Stint project + clip,
/// uploads the rendered video, and returns a public share link the reviewer
/// (coach, teammate, client) opens to leave frame-pinned comments. Closes the
/// loop: find → mark → tag → **review** → re-cut.
///
/// The request-construction helpers (`shareURL`, `multipartVideoBody`,
/// `ownerCookieHeader`) are pure and unit-tested. The live round-trip is
/// validated against a running Stint server (configured in Settings → Bridges).
enum StintBridge {

    // MARK: - Config

    struct Config {
        var baseURL: URL

        /// Reads the Stint server URL from Settings; nil if unset/invalid.
        static var current: Config? {
            let raw = (AppPreferences.defaults.string(forKey: "stintServerURL") ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty,
                  let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return Config(baseURL: url)
        }
    }

    enum StintError: LocalizedError {
        case notConfigured, notReady, renderFailed, http(Int), badResponse, alreadySending
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set your Stint server URL in Settings → Bridges"
            case .notReady:      return "Library not ready"
            case .renderFailed:  return "Couldn't render the clip for review"
            case .http(let c):   return "Stint server returned HTTP \(c)"
            case .badResponse:   return "Unexpected response from the Stint server"
            case .alreadySending: return "These clips are already being sent"
            }
        }
    }

    // MARK: - Pure request construction (unit-tested)

    /// The public project share link a guest opens — `<base>/p/:id?t=<token>`,
    /// matching Stint's web route + share-token auth.
    static func shareURL(base: URL, projectID: String, shareToken: String) -> URL {
        let target = base.appendingPathComponent("p").appendingPathComponent(projectID)
        var comps = URLComponents(url: target, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "t", value: shareToken)]
        return comps?.url ?? target
    }

    /// Stint authenticates the owner by an `owner_<projectId>` cookie equal to
    /// the project's owner key (returned at creation).
    static func ownerCookieHeader(projectID: String, ownerKey: String) -> String {
        "owner_\(projectID)=\(ownerKey)"
    }

    /// A `multipart/form-data` body for a single file field plus text fields.
    static func multipartVideoBody(
        fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        extraFields: [String: String],
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (key, value) in extraFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: - Network (validated against a running Stint server)

    struct CreatedProject: Decodable {
        struct ProjectInfo: Decodable { let id: String }
        let project: ProjectInfo
        let ownerKey: String
        let shareToken: String
    }
    private struct CreatedClip: Decodable {
        struct ClipInfo: Decodable { let id: String }
        let clip: ClipInfo
    }

    private static func createProject(base: URL, name: String) async throws -> CreatedProject {
        var req = URLRequest(url: base.appendingPathComponent("api/projects"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        return try JSONDecoder().decode(CreatedProject.self, from: data)
    }

    private static func createClip(base: URL, projectID: String, ownerKey: String, name: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("api/projects/\(projectID)/clips"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ownerCookieHeader(projectID: projectID, ownerKey: ownerKey), forHTTPHeaderField: "Cookie")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        return try JSONDecoder().decode(CreatedClip.self, from: data).clip.id
    }

    private static func uploadVideo(
        base: URL, projectID: String, ownerKey: String,
        stintClipID: String, fileURL: URL, durationSeconds: Double
    ) async throws {
        let boundary = "clipx-\(UUID().uuidString)"
        // Assemble the multipart body on disk and upload from the file, so a
        // large render is never held wholesale in memory (it's streamed in
        // chunks through both the writer and URLSession).
        let bodyURL = try writeMultipartVideoBodyFile(
            fieldName: "video",
            filename: fileURL.lastPathComponent,
            mimeType: "video/mp4",
            videoFileURL: fileURL,
            extraFields: ["durationSeconds": String(format: "%.3f", durationSeconds)],
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var req = URLRequest(url: base.appendingPathComponent("api/clips/\(stintClipID)/video"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(ownerCookieHeader(projectID: projectID, ownerKey: ownerKey), forHTTPHeaderField: "Cookie")
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: bodyURL)
        try check(resp)
    }

    /// Writes a `multipart/form-data` body to a temp file, streaming the video
    /// in chunks rather than loading it into a `Data`. Returns the temp URL; the
    /// caller is responsible for deleting it. Mirrors `multipartVideoBody`'s wire
    /// format (which stays as the pure, unit-tested reference).
    static func writeMultipartVideoBodyFile(
        fieldName: String,
        filename: String,
        mimeType: String,
        videoFileURL: URL,
        extraFields: [String: String],
        boundary: String
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipx-upload-\(UUID().uuidString).multipart")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: tmp) } }
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        func write(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }
        for (key, value) in extraFields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            try write("\(value)\r\n")
        }
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        try write("Content-Type: \(mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: videoFileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try out.synchronize()
        completed = true
        return tmp
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw StintError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw StintError.http(http.statusCode) }
    }

    // MARK: - Render

    struct RenderedClip {
        let fileURL: URL
        let durationSeconds: Double
        let name: String
    }

    private static func renderClip(clipID: Int64, database: Database) async throws -> RenderedClip {
        guard let clip = try database.read({ try Clip.fetchOne($0, key: clipID) }),
              let source = try database.read({ try Source.fetchOne($0, key: clip.sourceID) }) else {
            throw StintError.notReady
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipx-review-\(clipID)-\(UUID().uuidString).mp4")
        let request = try ClipRenderRequest(clip: clip, source: source, preset: .youtube1080p, outputURL: tmp)
        let result = try await ClipRenderer.render(request)
        return RenderedClip(fileURL: tmp, durationSeconds: Double(result.durationMs) / 1000,
                            name: clip.name ?? "Clip \(clipID)")
    }

    // MARK: - Durable transfer

    struct Client {
        var createProject: (URL, String) async throws -> CreatedProject
        var createClip: (URL, String, String, String) async throws -> String
        var uploadVideo: (URL, String, String, String, URL, Double) async throws -> Void

        static let live = Client(
            createProject: { try await StintBridge.createProject(base: $0, name: $1) },
            createClip: { try await StintBridge.createClip(base: $0, projectID: $1, ownerKey: $2, name: $3) },
            uploadVideo: { try await StintBridge.uploadVideo(base: $0, projectID: $1, ownerKey: $2,
                                                           stintClipID: $3, fileURL: $4, durationSeconds: $5) }
        )
    }

    @MainActor private static var activeTransfers: Set<String> = []

    private struct CommentRefreshKey: Hashable {
        let database: ObjectIdentifier
        let clipID: Int64
    }
    @MainActor private static var commentRefreshes: [CommentRefreshKey: UUID] = [:]

    /// Each remote commit is recorded before proceeding. Retrying the same
    /// unfinished selection reuses its project and clip IDs, skips completed
    /// uploads, and retries the failed upload against the same remote clip.
    @MainActor
    static func transfer(
        clipIDs: [Int64], projectName: String, config: Config, database: Database,
        client: Client = .live,
        render: ((Int64) async throws -> RenderedClip)? = nil
    ) async throws -> URL {
        let ids = Array(Set(clipIDs.filter { $0 > 0 })).sorted()
        guard !ids.isEmpty else { throw StintError.notReady }
        let keyData = try JSONEncoder().encode([config.baseURL.absoluteString, projectName, ids.map(String.init).joined(separator: ",")])
        let key = String(decoding: keyData, as: UTF8.self)
        guard activeTransfers.insert(key).inserted else { throw StintError.alreadySending }
        defer { activeTransfers.remove(key) }
        try database.read { db in
            for id in ids {
                guard try Clip.fetchOne(db, key: id) != nil else { throw StintError.notReady }
            }
        }
        let saved = try database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT b.id, b.project_id, p.owner_key, p.share_token
                FROM stint_transfer_batches b JOIN stint_projects p ON p.project_id = b.project_id
                WHERE b.selection_key = ? AND b.completed = 0 ORDER BY b.created_at DESC LIMIT 1
                """, arguments: [key])
        }
        let batchID: String
        let projectID: String
        let ownerKey: String
        let shareToken: String
        if let saved {
            batchID = saved["id"]
            projectID = saved["project_id"]
            ownerKey = saved["owner_key"]
            shareToken = saved["share_token"]
        } else {
            try Task.checkCancellation()
            let created = try await client.createProject(config.baseURL, projectName)
            batchID = UUID().uuidString
            projectID = created.project.id
            ownerKey = created.ownerKey
            shareToken = created.shareToken
            try database.write { db in
                let now = Int64(Date().timeIntervalSince1970)
                try db.execute(sql: "INSERT INTO stint_projects(project_id, owner_key, share_token, base_url, created_at) VALUES(?,?,?,?,?)",
                               arguments: [projectID, ownerKey, shareToken, config.baseURL.absoluteString, now])
                try db.execute(sql: "INSERT INTO stint_transfer_batches(id, selection_key, project_id, created_at) VALUES(?,?,?,?)",
                               arguments: [batchID, key, projectID, now])
                for id in ids {
                    try db.execute(sql: "INSERT INTO stint_transfer_items(batch_id, clip_id) VALUES(?,?)", arguments: [batchID, id])
                }
            }
        }
        let link = shareURL(base: config.baseURL, projectID: projectID, shareToken: shareToken)
        for id in ids {
            try Task.checkCancellation()
            guard let item = try database.read({ try Row.fetchOne($0, sql: "SELECT stint_clip_id, uploaded FROM stint_transfer_items WHERE batch_id = ? AND clip_id = ?", arguments: [batchID, id]) }) else {
                throw StintError.notReady
            }
            if (item["uploaded"] as Bool) { continue }
            let rendered: RenderedClip
            if let render { rendered = try await render(id) }
            else { rendered = try await renderClip(clipID: id, database: database) }
            defer { try? FileManager.default.removeItem(at: rendered.fileURL) }
            let remoteClipID: String
            if let savedID: String = item["stint_clip_id"] {
                remoteClipID = savedID
            } else {
                remoteClipID = try await client.createClip(config.baseURL, projectID, ownerKey, rendered.name)
                try database.write { db in
                    try db.execute(sql: "UPDATE stint_transfer_items SET stint_clip_id = ? WHERE batch_id = ? AND clip_id = ?",
                                   arguments: [remoteClipID, batchID, id])
                }
            }
            try await client.uploadVideo(config.baseURL, projectID, ownerKey, remoteClipID,
                                         rendered.fileURL, rendered.durationSeconds)
            // Do not check cancellation between a successful remote commit and
            // its local receipt. The next loop iteration observes cancellation.
            try database.write { db in
                try db.execute(sql: "UPDATE stint_transfer_items SET uploaded = 1 WHERE batch_id = ? AND clip_id = ?",
                               arguments: [batchID, id])
                try db.execute(sql: "UPDATE clips SET review_url = ?, stint_project_id = ?, stint_clip_id = ? WHERE id = ?",
                               arguments: [link.absoluteString, projectID, remoteClipID, id])
            }
            commentRefreshes[CommentRefreshKey(database: ObjectIdentifier(database), clipID: id)] = nil
        }
        try database.write { db in
            try db.execute(sql: "UPDATE stint_transfer_batches SET completed = 1 WHERE id = ?", arguments: [batchID])
        }
        return link
    }

    @MainActor
    static func sendToReview(clipIDs: [Int64], projectName: String) async {
        guard let config = Config.current else {
            AppState.shared.showToast(StintError.notConfigured.localizedDescription, level: .warning)
            return
        }
        guard let database = AppEnvironment.shared.database else { return }
        guard !clipIDs.isEmpty else {
            AppState.shared.showToast("No clips to send", level: .warning)
            return
        }
        AppState.shared.showToast("Preparing \(clipIDs.count) clip(s) for review…", level: .info)
        defer { AppState.shared.libraryRevision &+= 1 }
        do {
            let link = try await transfer(clipIDs: clipIDs, projectName: projectName, config: config, database: database)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(link.absoluteString, forType: .string)
            AppState.shared.showToast("Review link copied — share it for frame-pinned comments", level: .success,
                                      actionLabel: "Open") { NSWorkspace.shared.open(link) }
        } catch is CancellationError {
            AppState.shared.showToast("Review upload cancelled. Send again to continue.", level: .info)
        } catch {
            AppState.shared.showToast("Send to review failed: \(error.localizedDescription). Send again to resume.", level: .error)
        }
    }

    // MARK: - Pull-back (Stint comments → clip notes)

    struct StintComment: Decodable {
        let id: String
        let t: Double?
        let authorName: String
        let body: String
        let resolved: Bool
        let parentCommentId: String?
        let transcript: String?
    }
    private struct CommentsResponse: Decodable { let comments: [StintComment] }

    /// m:ss for a comment's frame timestamp (pure).
    static func mmss(_ t: Double?) -> String {
        guard let t, t.isFinite, t >= 0, t < Double(Int.max) else { return "—" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Render a threaded digest of comments + the total count (pure, testable).
    static func formatComments(_ comments: [StintComment]) -> (text: String, count: Int) {
        let knownIDs = Set(comments.map(\.id))
        var children: [String: [StintComment]] = [:]
        for comment in comments {
            if let parent = comment.parentCommentId { children[parent, default: []].append(comment) }
        }
        var visited: Set<String> = []
        var lines: [String] = []
        func append(_ comment: StintComment, depth: Int) {
            guard visited.insert(comment.id).inserted else { return }
            let body = !comment.body.isEmpty ? comment.body :
                comment.transcript.map { "[voice] \($0)" } ?? "[voice note]"
            let mark = comment.resolved ? " (resolved)" : ""
            let prefix = depth == 0 ? "[\(mmss(comment.t))] " : "reply "
            let indentation = String(repeating: "    ", count: min(depth, 16))
            lines.append("\(indentation)- \(prefix)\(comment.authorName)\(mark): \(body)")
            if depth < 64 {
                for child in children[comment.id] ?? [] { append(child, depth: depth + 1) }
            }
        }
        for comment in comments where comment.parentCommentId == nil || !knownIDs.contains(comment.parentCommentId ?? "") {
            append(comment, depth: 0)
        }
        // Orphans and malformed cycles still show their text once.
        for comment in comments where !visited.contains(comment.id) { append(comment, depth: 0) }
        return (lines.joined(separator: "\n"), visited.count)
    }

    /// Merge a fresh review digest into a clip's notes, replacing any prior
    /// review block so repeated refreshes don't stack (pure, testable).
    static func mergeReviewNotes(existing: String?, digest: String) -> String {
        let start = "<!-- clipx:review -->"
        let end = "<!-- /clipx:review -->"
        var notes = existing ?? ""
        let cleanDigest = digest.replacingOccurrences(of: end, with: "&lt;!-- /clipx:review --&gt;")
        let block = cleanDigest.isEmpty ? "" : "\(start)\nReview comments:\n\(cleanDigest)\n\(end)"
        if let begin = notes.range(of: start) {
            if let finish = notes.range(of: end, range: begin.upperBound..<notes.endIndex) {
                notes.replaceSubrange(begin.lowerBound..<finish.upperBound, with: block)
                return notes.trimmingCharacters(in: .newlines)
            }
            // Legacy imports had no closing delimiter. Its tail may contain
            // user edits, so archive that ambiguous block intact once instead
            // of guessing where the user's text starts.
            notes.replaceSubrange(begin, with: "<!-- clipx:review-legacy -->")
        }
        guard !block.isEmpty else { return notes }
        return notes.isEmpty ? block : notes + "\n\n" + block
    }

    private static func getComments(base: URL, projectID: String, ownerKey: String, stintClipID: String) async throws -> [StintComment] {
        var req = URLRequest(url: base.appendingPathComponent("api/clips/\(stintClipID)/comments"))
        req.setValue(ownerCookieHeader(projectID: projectID, ownerKey: ownerKey), forHTTPHeaderField: "Cookie")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        return try JSONDecoder().decode(CommentsResponse.self, from: data).comments
    }

    /// Pulls review comments back from Stint for the given clips (or every
    /// review-linked clip when `clipIDs` is empty), merging them into each
    /// clip's notes and caching the count. Visible in the Inspector's notes.
    @MainActor
    static func refreshComments(
        clipIDs: [Int64], database: Database? = nil,
        fetch: ((URL, String, String, String) async throws -> [StintComment])? = nil
    ) async {
        guard let db = database ?? AppEnvironment.shared.database else { return }
        struct Linked { let clipID: Int64; let stintClipID: String; let projectID: String }
        let linked: [Linked] = (try? db.read { dbc -> [Linked] in
            let sql: String
            var args: [DatabaseValueConvertible] = []
            if clipIDs.isEmpty {
                sql = "SELECT id, stint_clip_id, stint_project_id FROM clips WHERE stint_clip_id IS NOT NULL"
            } else {
                let ph = clipIDs.map { _ in "?" }.joined(separator: ",")
                sql = "SELECT id, stint_clip_id, stint_project_id FROM clips WHERE stint_clip_id IS NOT NULL AND id IN (\(ph))"
                args = clipIDs.map { $0 as DatabaseValueConvertible }
            }
            let rows = try Row.fetchAll(dbc, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { r in
                guard let cid: Int64 = r["id"],
                      let scid: String = r["stint_clip_id"],
                      let pid: String = r["stint_project_id"] else { return nil }
                return Linked(clipID: cid, stintClipID: scid, projectID: pid)
            }
        }) ?? []

        guard !linked.isEmpty else {
            AppState.shared.showToast("No clips have been sent for review yet", level: .warning)
            return
        }

        let generation = UUID()
        let keys = Dictionary(uniqueKeysWithValues: linked.map {
            ($0.clipID, CommentRefreshKey(database: ObjectIdentifier(db), clipID: $0.clipID))
        })
        for key in keys.values { commentRefreshes[key] = generation }
        var updated = 0
        defer {
            for key in keys.values where commentRefreshes[key] == generation { commentRefreshes[key] = nil }
            // Earlier clips remain committed even if a later request fails.
            if updated > 0 { AppState.shared.libraryRevision &+= 1 }
        }

        func creds(forProject pid: String) -> (ownerKey: String, baseURL: URL)? {
            try? db.read { dbc -> (String, URL)? in
                guard let row = try Row.fetchOne(dbc, sql: "SELECT owner_key, base_url FROM stint_projects WHERE project_id = ?", arguments: [pid]),
                      let ok: String = row["owner_key"],
                      let burl: String = row["base_url"],
                      let u = URL(string: burl) else { return nil }
                return (ok, u)
            } ?? nil
        }

        var total = 0
        do {
            for item in linked {
                try Task.checkCancellation()
                guard let key = keys[item.clipID], commentRefreshes[key] == generation else { continue }
                guard let c = creds(forProject: item.projectID) else { continue }
                let comments: [StintComment]
                if let fetch { comments = try await fetch(c.baseURL, item.projectID, c.ownerKey, item.stintClipID) }
                else { comments = try await getComments(base: c.baseURL, projectID: item.projectID, ownerKey: c.ownerKey, stintClipID: item.stintClipID) }
                try Task.checkCancellation()
                guard commentRefreshes[key] == generation else { continue }
                let digest = formatComments(comments)
                let applied = try db.write { dbc -> Bool in
                    guard let current = try Clip.fetchOne(dbc, key: item.clipID),
                          current.stintProjectId == item.projectID,
                          current.stintClipId == item.stintClipID else { return false }
                    let merged = mergeReviewNotes(existing: current.notes, digest: digest.text)
                    try dbc.execute(
                        sql: "UPDATE clips SET notes = ?, review_comment_count = ? WHERE id = ?",
                        arguments: [merged, digest.count, item.clipID]
                    )
                    return true
                }
                if applied { total += digest.count; updated += 1 }
            }
            if updated > 0 { AppState.shared.showToast("Pulled \(total) review comment(s) from Stint", level: .success) }
        } catch is CancellationError {
            return
        } catch {
            if keys.values.contains(where: { commentRefreshes[$0] == generation }) {
                AppState.shared.showToast("Couldn't fetch comments: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
