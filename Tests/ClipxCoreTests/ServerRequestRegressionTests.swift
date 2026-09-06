import XCTest
@testable import Clipx

final class ServerRequestRegressionTests: XCTestCase {
    private func parse(_ wire: String) -> HTTPRequest.ParseResult {
        HTTPRequest.parse(buffer: Data(wire.utf8))
    }

    func test_completeRequestRetainsEmptyQueryValuesAndBody() throws {
        let wire = "POST /api?q=hello%20world&empty=&flag HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc"
        guard case .complete(let request) = parse(wire) else { return XCTFail("Expected complete request") }
        XCTAssertEqual(request.path, "/api")
        XCTAssertEqual(request.query, ["q": "hello world", "empty": "", "flag": ""])
        XCTAssertEqual(request.body, Data("abc".utf8))
        let bytes = Data(wire.utf8)
        let sliced = (Data([0, 0, 0]) + bytes).dropFirst(3)
        guard case .complete(let slicedRequest) = HTTPRequest.parse(buffer: sliced) else {
            return XCTFail("Parsing must respect a Data slice's nonzero start index")
        }
        XCTAssertEqual(slicedRequest.body, request.body)
        for count in 0..<bytes.count {
            guard case .incomplete = HTTPRequest.parse(buffer: Data(bytes.prefix(count))) else {
                return XCTFail("A valid prefix must remain incomplete at byte \(count)")
            }
        }
    }

    func test_malformedUnauthenticatedFramingIsTerminal() {
        let wires = [
            "GET /?= HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "GET /?=value HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "GET /?q=%ZZ HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: +1\r\n\r\nx",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9223372036854775808\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: localhost\r\nHost: evil.com\r\n\r\n",
            "GET / HTTP/1.1\r\nBrokenHeader\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nunframed body",
            "GET / HTTP/2\r\nHost: localhost\r\n\r\n"
        ]
        for wire in wires {
            guard case .malformed = parse(wire) else { XCTFail("Expected malformed: \(wire)"); continue }
        }
    }

    func test_oversizeHeadersAndAdvertisedBodiesAreRejectedBeforeBuffering() {
        let wire = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(HTTPRequest.maxRequestBytes)\r\n\r\n"
        guard case .tooLarge = parse(wire) else { return XCTFail("Advertised body exceeds request budget") }
        guard case .tooLarge = HTTPRequest.parse(buffer: Data(repeating: 65, count: HTTPRequest.maxHeaderBytes + 1)) else {
            return XCTFail("Header cap must apply before separator arrives")
        }
    }
}
