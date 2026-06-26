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
            let raw = (UserDefaults.standard.string(forKey: "stintServerURL") ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty,
                  let url = URL(string: raw),
                  url.scheme != nil, url.host != nil else { return nil }
            return Config(baseURL: url)
        }
    }

    enum StintError: LocalizedError {
        case notConfigured, notReady, renderFailed, http(Int), badResponse
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set your Stint server URL in Settings → Bridges"
            case .notReady:      return "Library not ready"
            case .renderFailed:  return "Couldn't render the clip for review"
            case .http(let c):   return "Stint server returned HTTP \(c)"
            case .badResponse:   return "Unexpected response from the Stint server"
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

    private struct CreatedProject: Decodable {
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
    private static func writeMultipartVideoBodyFile(
        fieldName: String,
        filename: String,
        mimeType: String,
        videoFileURL: URL,
        extraFields: [String: String],
        boundary: String
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipx-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        func write(_ s: String) { out.write(Data(s.utf8)) }
        for (key, value) in extraFields {
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            write("\(value)\r\n")
        }
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        write("Content-Type: \(mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: videoFileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            out.write(chunk)
        }
        write("\r\n--\(boundary)--\r\n")
        return tmp
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw StintError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw StintError.http(http.statusCode) }
    }

    // MARK: - Render

    /// Renders a clip's in/out range to a temp mp4 using the same backend the
    /// export pipeline uses, so the reviewer gets exactly the cut.
    private static func renderClip(clipID: Int64) async throws -> (fileURL: URL, durationSeconds: Double, name: String) {
        guard let db = AppEnvironment.shared.database else { throw StintError.notReady }
        guard let clip: Clip = try db.read({ try Clip.fetchOne($0, key: clipID) }),
              let source: Source = try db.read({ try Source.fetchOne($0, key: clip.sourceID) }) else {
            throw StintError.notReady
        }
        let fps = Double(source.fps ?? 0)
        let inMs = fps > 0 ? FrameMath.snapToFrame(ms: clip.inMs, fps: fps) : clip.inMs
        let outMs = fps > 0 ? FrameMath.snapToFrame(ms: clip.outMs, fps: fps) : clip.outMs
        let preset = ExportPreset.youtube1080p
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipx-review-\(clipID)-\(UUID().uuidString).mp4")
        let speed = source.speed
        // The rendered clip is sped up, so its real duration shrinks by `speed`.
        let renderedSeconds = Double(outMs - inMs) / 1000 / max(0.25, speed)
        #if DIRECT_BUILD
        let args = FFmpegBackend.buildArguments(
            sourcePath: source.path, inMs: inMs, outMs: outMs,
            preset: preset, outputPath: tmp.path, rotation: source.rotation,
            speed: speed
        )
        let code = try await FFmpegBackend.run(
            arguments: args, durationSec: renderedSeconds,
            onCancellerRegistered: { _ in }, onProgress: { _ in }
        )
        if code != 0 { throw StintError.renderFailed }
        #else
        try await AVFoundationBackend.export(
            sourcePath: source.path, inMs: inMs, outMs: outMs,
            preset: preset, outputPath: tmp.path, rotation: source.rotation,
            speed: speed,
            onCancellerRegistered: { _ in }, onProgress: { _ in }
        )
        #endif
        return (tmp, renderedSeconds, clip.name ?? "Clip \(clipID)")
    }

    // MARK: - Orchestration

    /// Renders the given clips, pushes them into a fresh Stint review project,
    /// stores the share link on each clip, copies it to the clipboard, and
    /// offers to open it. Toasts narrate progress + failures.
    @MainActor
    static func sendToReview(clipIDs: [Int64], projectName: String) async {
        guard let config = Config.current else {
            AppState.shared.showToast(StintError.notConfigured.localizedDescription, level: .warning)
            return
        }
        let ids = clipIDs.filter { $0 > 0 }
        guard !ids.isEmpty else {
            AppState.shared.showToast("No clips to send", level: .warning)
            return
        }
        AppState.shared.showToast("Rendering \(ids.count) clip(s) for review…", level: .info)
        do {
            let project = try await createProject(base: config.baseURL, name: projectName)
            let pid = project.project.id
            var stintClipByClip: [Int64: String] = [:]
            for cid in ids {
                let render = try await renderClip(clipID: cid)
                let stintClipID = try await createClip(
                    base: config.baseURL, projectID: pid,
                    ownerKey: project.ownerKey, name: render.name
                )
                try await uploadVideo(
                    base: config.baseURL, projectID: pid,
                    ownerKey: project.ownerKey, stintClipID: stintClipID,
                    fileURL: render.fileURL, durationSeconds: render.durationSeconds
                )
                try? FileManager.default.removeItem(at: render.fileURL)
                stintClipByClip[cid] = stintClipID
            }
            let link = shareURL(base: config.baseURL, projectID: pid, shareToken: project.shareToken)
            if let db = AppEnvironment.shared.database {
                try? db.write { dbc in
                    // Remember the project's creds so comments can be pulled back.
                    try dbc.execute(
                        sql: "INSERT OR REPLACE INTO stint_projects(project_id, owner_key, share_token, base_url, created_at) VALUES(?,?,?,?,?)",
                        arguments: [pid, project.ownerKey, project.shareToken, config.baseURL.absoluteString, Int64(Date().timeIntervalSince1970)]
                    )
                    for cid in ids {
                        try dbc.execute(
                            sql: "UPDATE clips SET review_url = ?, stint_project_id = ?, stint_clip_id = ? WHERE id = ?",
                            arguments: [link.absoluteString, pid, stintClipByClip[cid], cid]
                        )
                    }
                }
            }
            AppState.shared.libraryRevision &+= 1
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(link.absoluteString, forType: .string)
            AppState.shared.showToast(
                "Review link copied — share it for frame-pinned comments",
                level: .success,
                actionLabel: "Open"
            ) {
                NSWorkspace.shared.open(link)
            }
        } catch {
            AppState.shared.showToast("Send to review failed: \(error.localizedDescription)", level: .error)
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
        guard let t, t >= 0 else { return "—" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Render a threaded digest of comments + the total count (pure, testable).
    static func formatComments(_ comments: [StintComment]) -> (text: String, count: Int) {
        var childrenByParent: [String: [StintComment]] = [:]
        for c in comments where c.parentCommentId != nil {
            childrenByParent[c.parentCommentId!, default: []].append(c)
        }
        func bodyText(_ c: StintComment) -> String {
            if !c.body.isEmpty { return c.body }
            if let t = c.transcript, !t.isEmpty { return "[voice] \(t)" }
            return "[voice note]"
        }
        var lines: [String] = []
        for c in comments where c.parentCommentId == nil {
            let mark = c.resolved ? " (resolved)" : ""
            lines.append("- [\(mmss(c.t))] \(c.authorName)\(mark): \(bodyText(c))")
            for reply in childrenByParent[c.id] ?? [] {
                lines.append("    - reply \(reply.authorName): \(bodyText(reply))")
            }
        }
        return (lines.joined(separator: "\n"), comments.count)
    }

    /// Merge a fresh review digest into a clip's notes, replacing any prior
    /// review block so repeated refreshes don't stack (pure, testable).
    static func mergeReviewNotes(existing: String?, digest: String) -> String {
        let marker = "<!-- clipx:review -->"
        var base = existing ?? ""
        if let r = base.range(of: marker) {
            base = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let block = "\(marker)\nReview comments:\n\(digest)"
        return base.isEmpty ? block : base + "\n\n" + block
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
    static func refreshComments(clipIDs: [Int64]) async {
        guard let db = AppEnvironment.shared.database else { return }
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
                guard let c = creds(forProject: item.projectID) else { continue }
                let comments = try await getComments(base: c.baseURL, projectID: item.projectID, ownerKey: c.ownerKey, stintClipID: item.stintClipID)
                let digest = formatComments(comments)
                total += digest.count
                let existing: String? = try? db.read { try Clip.fetchOne($0, key: item.clipID)?.notes }
                let merged = digest.count > 0 ? mergeReviewNotes(existing: existing, digest: digest.text) : existing
                try? db.write { dbc in
                    try dbc.execute(
                        sql: "UPDATE clips SET notes = ?, review_comment_count = ? WHERE id = ?",
                        arguments: [merged, digest.count, item.clipID]
                    )
                }
            }
            AppState.shared.libraryRevision &+= 1
            AppState.shared.showToast("Pulled \(total) review comment(s) from Stint", level: .success)
        } catch {
            AppState.shared.showToast("Couldn't fetch comments: \(error.localizedDescription)", level: .error)
        }
    }
}
