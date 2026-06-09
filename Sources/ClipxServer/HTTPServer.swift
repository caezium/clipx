import Foundation
import Network

/// Tiny Network.framework-based HTTP/1.1 server. Sufficient for the embedded
/// Clipx web UI: a handful of GET/POST routes serving JSON + static HTML.
/// Listens on all local interfaces so phone or laptop on the same Wi-Fi
/// can connect.
///
/// NOT meant for the public internet. Binds to a high port (default 7878),
/// no TLS, and the pairing-code gate is the only auth.
@MainActor
final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private let portValue: NWEndpoint.Port
    private var handler: Handler?
    private let serverQueue = DispatchQueue(label: "com.clipx.server", qos: .userInitiated)

    /// Public for the Settings UI to display "your phone connects to
    /// http://<this-mac>:7878".
    let port: UInt16

    private(set) var isRunning = false

    init(port: UInt16 = 7878) {
        self.port = port
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            self.portValue = NWEndpoint.Port(integerLiteral: 7878)
            return
        }
        self.portValue = endpointPort
    }

    func start(handler: @escaping Handler) throws {
        guard !isRunning else { return }
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        listener = try NWListener(using: params, on: portValue)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ClipxLog.app.info("HTTPServer ready on port \(self?.port ?? 0)")
            case .failed(let error):
                ClipxLog.app.error("HTTPServer failed: \(String(describing: error), privacy: .public)")
                Task { @MainActor in self?.stop() }
            default:
                break
            }
        }
        listener?.start(queue: serverQueue)
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private nonisolated func accept(connection: NWConnection) {
        connection.start(queue: serverQueue)
        // Slowloris / idle guard: drop a connection that hasn't delivered a
        // complete request within the window. Cancelled once parsing. (#7)
        let timeout = DispatchWorkItem { connection.cancel() }
        serverQueue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private nonisolated func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var newBuffer = buffer
            if let data, !data.isEmpty { newBuffer.append(data) }
            // Bound memory: drop a request that blows past the size cap. (#7)
            if HTTPRequest.exceedsLimit(newBuffer) {
                timeout.cancel()
                connection.cancel()
                return
            }
            if let request = HTTPRequest.tryParse(buffer: newBuffer) {
                timeout.cancel()
                Task { @MainActor in
                    await self.respond(to: request, on: connection)
                }
                return
            }
            if isComplete || error != nil {
                timeout.cancel()
                connection.cancel()
                return
            }
            // Need more bytes; keep buffering.
            self.receive(on: connection, buffer: newBuffer, timeout: timeout)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let response: HTTPResponse
        if let handler {
            response = await handler(request)
        } else {
            response = .serverError("No handler registered")
        }
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
