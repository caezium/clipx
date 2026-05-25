import Foundation

/// FSEvents-backed folder watcher. When a file is added or modified in a
/// watched root, the corresponding source is (re-)indexed. Multiple roots
/// share a single FSEvents stream.
///
/// The C callback runs on the main queue (we set it via
/// `FSEventStreamSetDispatchQueue`), so it can access `lastSeenEventId` and
/// `indexer` safely. The actual indexing hops to the `Indexer` actor's
/// executor so the main thread doesn't block.
@MainActor
final class FolderWatcher {
    /// Indexer is an actor — calls hop off the main queue automatically.
    /// Exposed as `nonisolated` so the C callback can reach it without an
    /// await round-trip.
    nonisolated let indexer: Indexer
    private let bookmarkStore: BookmarkStore
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    /// Last event id observed by the callback. Used so a stream
    /// restart (add/remove folder) doesn't drop events that arrived in the
    /// gap — without this, every restart used `kFSEventStreamEventIdSinceNow`.
    private var lastSeenEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    init(indexer: Indexer, bookmarkStore: BookmarkStore) {
        self.indexer = indexer
        self.bookmarkStore = bookmarkStore
    }

    /// Restores access to all stored library folders and starts a watcher
    /// covering them. Called at app launch from `AppEnvironment.bootstrap()`.
    func resumeAll() {
        let urls = bookmarkStore.resumeAccess()
        paths = uniquePaths(from: urls.map(\.path))
        guard !paths.isEmpty else { return }
        startStream(paths: paths, sinceEventId: lastSeenEventId)

        // One-shot rescan so new files added while the app was closed get
        // picked up. Cheap per-file now that `Indexer.indexFile` skips on
        // unchanged mtime+size.
        for url in urls {
            let idx = indexer
            Task.detached { await idx.index(folder: url) }
        }
    }

    func add(folder url: URL) {
        do {
            try bookmarkStore.addFolder(url: url)
            // Dedupe — the bookmark store is already idempotent, but `paths`
            // backs FSEvents and a duplicate entry there would deliver every
            // event twice.
            if !paths.contains(url.path) { paths.append(url.path) }
            restartStream()
            let idx = indexer
            Task.detached { await idx.index(folder: url) }
        } catch {
            ClipxLog.watcher.error("add failed: \(String(describing: error), privacy: .public)")
        }
    }

    func remove(folderPath path: String) {
        bookmarkStore.removeFolder(path: path)
        paths.removeAll { $0 == path }
        restartStream()
    }

    func rescanAll() {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let idx = indexer
            Task.detached { await idx.index(folder: url) }
        }
    }

    func stopAll() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        bookmarkStore.stopAll()
    }

    private func restartStream() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !paths.isEmpty else { return }
        startStream(paths: paths, sinceEventId: lastSeenEventId)
    }

    private func startStream(paths: [String], sinceEventId: FSEventStreamEventId) {
        // `passRetained` + a matching `release` callback so the watcher can't
        // be deallocated while a queued FSEvents callback is still in flight.
        // Previous version used `passUnretained` with `retain: nil` — UAF
        // window during shutdown.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { rawInfo in
                guard let rawInfo else { return }
                Unmanaged<FolderWatcher>.fromOpaque(rawInfo).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FolderWatcher.callback,
            &context,
            paths as CFArray,
            sinceEventId,
            1.0, // 1s debounce
            flags
        ) else {
            // FSEventStreamCreate failed; release the retain we did above so
            // we don't leak self.
            Unmanaged<FolderWatcher>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private nonisolated func uniquePaths(from input: [String]) -> [String] {
        var seen = Set<String>()
        return input.filter { seen.insert($0).inserted }
    }

    /// Receives FSEvents on the main queue (configured via
    /// SetDispatchQueue). Filters to video files and dispatches indexing
    /// to the `Indexer` actor.
    nonisolated private static let callback: FSEventStreamCallback = {
        (_, info, count, evPathsRaw, evFlags, evIds) in
        guard let info = info else { return }
        // Unretained — release happens in the context's release callback.
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(evPathsRaw, to: NSArray.self) as? [String] ?? []
        var maxId: FSEventStreamEventId = 0
        for i in 0..<count {
            let id = evIds[i]
            if id > maxId { maxId = id }
            let flags = evFlags[i]
            let path = paths[i]
            let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let removed = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            guard isFile, !removed else { continue }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard Indexer.videoExtensions.contains(ext) else { continue }
            let idx = watcher.indexer
            Task.detached { await idx.indexFile(url) }
        }
        if maxId > 0 {
            // Update on the main actor — callback already runs on the main
            // queue but Swift's isolation doesn't know that, so hop.
            Task { @MainActor in
                if maxId > watcher.lastSeenEventId {
                    watcher.lastSeenEventId = maxId
                }
            }
        }
    }
}
