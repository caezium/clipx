import Foundation

/// One job's cancellation token. Cancellation is latched, including before a
/// backend has registered. Create a new token for every job; never reset it.
final class CancellerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var canceller: (@Sendable () -> Void)?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func set(_ c: (@Sendable () -> Void)?) {
        lock.lock()
        let shouldCancel = cancelled
        canceller = shouldCancel ? nil : c
        lock.unlock()
        if shouldCancel { c?() }
    }

    /// Fire the current canceller (if any) — used by "Cancel All".
    func cancel() {
        lock.lock()
        cancelled = true
        let c = canceller
        canceller = nil
        lock.unlock()
        c?()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}
