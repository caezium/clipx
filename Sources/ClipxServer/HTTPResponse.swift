import Foundation

/// HTTP/1.1 response builder. Stores body as `Data` so we can serve binaries
/// (thumbnails) as well as text. Connection: close — we don't keep-alive
/// because every request from the web frontend is independent.
struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Convenience constructors.
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("null".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
    }

    static func plain(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func bytes(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": contentType],
            body: data
        )
    }

    static func notFound(_ message: String = "Not found") -> HTTPResponse {
        plain(message, status: 404)
    }

    static func badRequest(_ message: String = "Bad request") -> HTTPResponse {
        plain(message, status: 400)
    }

    static func serverError(_ message: String = "Internal server error") -> HTTPResponse {
        plain(message, status: 500)
    }

    /// Serializes the response back to wire bytes.
    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = "\(body.count)"
        mergedHeaders["Connection"] = "close"
        // The web frontend is served from this same origin, so it needs no CORS
        // grant. A wildcard `Access-Control-Allow-Origin: *` would instead let
        // *any* website read these responses (with DNS-rebinding, even reach
        // the LAN), so we deliberately emit no permissive CORS header. (#4)
        for (name, value) in mergedHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}
