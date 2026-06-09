import Foundation

/// Thread-safe holder for a job's "stop the backend" closure.
///
/// The bug (#10): the pipeline stored the canceller via an async hop onto the
/// main actor, so cancelling in the first moments of a job found it still
/// unset — only the Swift task was cancelled, which doesn't stop an
/// `AVAssetExportSession` or ffmpeg `Process`. A backend registers its
/// canceller synchronously the instant work begins; this box makes it readable
/// synchronously by the cancel path with no window.
final class CancellerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var canceller: (@Sendable () -> Void)?

    func set(_ c: (@Sendable () -> Void)?) {
        lock.lock(); canceller = c; lock.unlock()
    }

    /// Fire the current canceller (if any) — used by "Cancel All".
    func cancel() {
        lock.lock(); let c = canceller; lock.unlock()
        c?()
    }
}
