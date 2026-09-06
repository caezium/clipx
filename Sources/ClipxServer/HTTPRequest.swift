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
    static let maxHeaderBytes = 32_768

    enum ParseResult {
        case incomplete
        case malformed
        case tooLarge
        case complete(HTTPRequest)
    }

    /// True once an in-progress buffer has blown past the size cap — the server
    /// drops the connection instead of buffering forever (memory DoS). (#7)
    static func exceedsLimit(_ buffer: Data) -> Bool {
        buffer.count > maxRequestBytes
    }

    /// Malformed framing is terminal, even when it arrives before pairing.
    /// Only `incomplete` permits the caller to keep buffering.
    static func parse(buffer: Data) -> ParseResult {
        guard !exceedsLimit(buffer) else { return .tooLarge }
        // Find the header/body boundary (CRLF CRLF).
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = buffer.range(of: sep) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard headerEnd.upperBound - buffer.startIndex <= maxHeaderBytes else { return .tooLarge }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .malformed }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return .malformed }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count == 3, isToken(parts[0]),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .malformed }
        let method = parts[0]
        let target = parts[1]
        guard target.hasPrefix("/"), !target.contains("#"),
              target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return .malformed }

        // Split path and query.
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let path = pathAndQuery.first ?? "/"
        var query: [String: String] = [:]
        if pathAndQuery.count > 1 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = kv.first, !rawKey.isEmpty,
                      let key = String(rawKey).removingPercentEncoding,
                      let value = (kv.count == 2 ? String(kv[1]) : "").removingPercentEncoding else {
                    return .malformed
                }
                query[key] = value
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isToken(name), value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                return .malformed
            }
            // Never choose one of two conflicting framing / authority values.
            if let old = headers[name] {
                guard !["content-length", "transfer-encoding", "host"].contains(name) else { return .malformed }
                headers[name] = old + (name == "cookie" ? "; " : ", ") + value
            } else { headers[name] = value }
        }
        guard headers["transfer-encoding"] == nil else { return .malformed }
        if parts[2] == "HTTP/1.1", headers["host"]?.isEmpty != false { return .malformed }

        let bodyStart = headerEnd.upperBound
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let contentLength = Int(rawLength) else { return .malformed }
        // Subtraction avoids overflowing an attacker-controlled length sum.
        guard contentLength <= maxRequestBytes - (bodyStart - buffer.startIndex) else { return .tooLarge }
        let available = buffer.endIndex - bodyStart
        guard available >= contentLength else { return .incomplete }
        guard available == contentLength else { return .malformed }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        return .complete(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    /// Compatibility helper for callers that only need a complete request.
    static func tryParse(buffer: Data) -> HTTPRequest? {
        if case .complete(let request) = parse(buffer: buffer) { return request }
        return nil
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    /// Best-effort JSON body decode.
    func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }
}
