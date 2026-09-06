import Foundation
import Network

/// The opt-in LAN server handles one request per connection. Framing and all
/// connection ownership stay here; route handlers only build responses.
@MainActor
final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private let portValue: NWEndpoint.Port
    private let bindToLoopback: Bool
    private var handler: Handler?
    private let serverQueue = DispatchQueue(label: "com.clipx.server", qos: .userInitiated)
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timeouts: [UUID: DispatchWorkItem] = [:]
    private var lastProgress: [UUID: Date] = [:]
    private var generation = UUID()
    let port: UInt16
    private(set) var isRunning = false
    var listeningPort: UInt16? { listener?.port?.rawValue }
    var onFailure: ((Error) -> Void)?
    var onReady: (() -> Void)?

    init(port: UInt16 = 7878, bindToLoopback: Bool = false) {
        self.port = port
        self.portValue = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 7878)
        self.bindToLoopback = bindToLoopback
    }

    func start(handler: @escaping Handler) throws {
        guard !isRunning else { return }
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if bindToLoopback { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: portValue) }
        let listener = try NWListener(using: params, on: portValue)
        self.listener = listener
        let generation = UUID()
        self.generation = generation
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == generation else {
                    connection.cancel()
                    return
                }
                self.accept(connection: connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    ClipxLog.app.info("HTTPServer ready on port \(self.port)")
                    self.onReady?()
                case .failed(let error):
                    ClipxLog.app.error("HTTPServer failed: \(String(describing: error), privacy: .public)")
                    self.stop()
                    self.onFailure?(error)
                default: break
                }
            }
        }
        isRunning = true
        listener.start(queue: serverQueue)
    }

    func stop() {
        generation = UUID()
        isRunning = false
        listener?.cancel()
        listener = nil
        handler = nil
        for id in Array(connections.keys) { finish(id) }
    }

    private func accept(connection: NWConnection) {
        // A per-request cap alone does not bound many slow clients.
        guard connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.finish(id) }
            default: break
            }
        }
        connection.start(queue: serverQueue)
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.finish(id) }
        }
        timeouts[id] = timeout
        serverQueue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive(on: connection, id: id, buffer: Data())
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequest.parse(buffer: buffer) {
                case .complete(let request):
                    self.timeouts.removeValue(forKey: id)?.cancel()
                    let timeout = DispatchWorkItem { [weak self] in
                        Task { @MainActor in self?.finish(id) }
                    }
                    self.timeouts[id] = timeout
                    self.serverQueue.asyncAfter(deadline: .now() + 30, execute: timeout)
                    self.tasks[id] = Task { @MainActor [weak self] in
                        guard let self, let handler = self.handler else { return }
                        let response = await handler(request)
                        guard !Task.isCancelled, self.connections[id] != nil else { return }
                        self.send(response, on: connection, id: id)
                    }
                case .malformed:
                    self.send(.badRequest("Malformed HTTP request"), on: connection, id: id)
                case .tooLarge:
                    self.send(.plain("Request too large", status: 413), on: connection, id: id)
                case .incomplete:
                    if isComplete || error != nil { self.finish(id) }
                    else { self.receive(on: connection, id: id, buffer: buffer) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        // Use an idle deadline so an actively streaming long video is not cut
        // off merely because its total transfer takes more than two minutes.
        lastProgress[id] = Date()
        scheduleResponseTimeout(id)
        let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.finish(id) }
        }
        let progress: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                self.lastProgress[id] = Date()
            }
        }
        if let file = response.fileBody {
            connection.send(content: response.serializeHead(), completion: .contentProcessed { error in
                guard error == nil else { completion(); return }
                Self.sendNextChunk(file, on: connection, progress: progress, completion: completion)
            })
        } else {
            connection.send(content: response.serialize(), completion: .contentProcessed { _ in completion() })
        }
    }

    /// Network.framework calls completions on serverQueue. Read one 64 KiB
    /// chunk only after the preceding send drains, so memory is independent of
    /// file size and slow clients cannot enqueue the whole video.
    private nonisolated static func sendNextChunk(
        _ file: HTTPResponse.FileBody, on connection: NWConnection,
        progress: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void
    ) {
        guard file.remaining > 0 else { completion(); return }
        do {
            let chunk = try file.readNextChunk()
            connection.send(content: chunk, completion: .contentProcessed { error in
                guard error == nil else { completion(); return }
                progress()
                sendNextChunk(file, on: connection, progress: progress, completion: completion)
            })
        } catch { completion() }
    }

    private func scheduleResponseTimeout(_ id: UUID, after seconds: TimeInterval = 120) {
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let last = self.lastProgress[id] else { return }
                let idle = Date().timeIntervalSince(last)
                if idle >= 120 { self.finish(id) }
                else { self.scheduleResponseTimeout(id, after: max(1, 120 - idle)) }
            }
        }
        timeouts[id] = timeout
        serverQueue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func finish(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        lastProgress[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
