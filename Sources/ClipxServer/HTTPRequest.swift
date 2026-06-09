import Foundation

/// Minimal HTTP/1.1 request parser. Handles the subset we actually need:
/// request line, headers, optional body. Chunked encoding is not supported
/// (the web frontend uses fixed-length bodies for the handful of writes).
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Upper bound on a single request (headers + body). Our writes are tiny
    /// JSON; anything larger is abuse. Caps unbounded buffering. (#7)
    static let maxRequestBytes = 1_048_576   // 1 MiB

    /// True once an in-progress buffer has blown past the size cap — the server
    /// drops the connection instead of buffering forever (memory DoS). (#7)
    static func exceedsLimit(_ buffer: Data) -> Bool {
        buffer.count > maxRequestBytes
    }

    /// Returns nil if the buffer doesn't yet contain a complete request.
    /// Caller should keep accumulating bytes and re-call.
    static func tryParse(buffer: Data) -> HTTPRequest? {
        // Find the header/body boundary (CRLF CRLF).
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = buffer.range(of: sep) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]

        // Split path and query.
        let pathAndQuery = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pathAndQuery.first ?? "/"
        var query: [String: String] = [:]
        if pathAndQuery.count > 1 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0].removingPercentEncoding ?? kv[0]] =
                        kv[1].removingPercentEncoding ?? kv[1]
                } else {
                    query[kv[0]] = ""
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    /// Best-effort JSON body decode.
    func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }
}
