import Foundation

/// FSEvents-backed folder watcher. When a file is added or modified in a
/// watched root, the corresponding source is (re-)indexed. Multiple roots
/// share a single FSEvents stream.
@MainActor
final class FolderWatcher {
    private let indexer: Indexer
    private let bookmarkStore: BookmarkStore
    private var stream: FSEventStreamRef?
    private var paths: [String] = []

    init(indexer: Indexer, bookmarkStore: BookmarkStore) {
        self.indexer = indexer
        self.bookmarkStore = bookmarkStore
    }

    /// Restores access to all stored library folders and starts a watcher
    /// covering them. Called at app launch from `AppEnvironment.bootstrap()`.
    func resumeAll() {
        let urls = bookmarkStore.resumeAccess()
        paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        startStream(paths: paths)

        // Kick off a one-shot rescan so new files added while the app was
        // closed get picked up immediately.
        for url in urls {
            Task { await indexer.index(folder: url) }
        }
    }

    func add(folder url: URL) {
        do {
            try bookmarkStore.addFolder(url: url)
            paths.append(url.path)
            restartStream()
            Task { await indexer.index(folder: url) }
        } catch {
            NSLog("FolderWatcher.add failed: \(error)")
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
            Task { await indexer.index(folder: url) }
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
        startStream(paths: paths)
    }

    private func startStream(paths: [String]) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
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
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1s debounce
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    nonisolated private static let callback: FSEventStreamCallback = {
        (_, info, count, evPathsRaw, evFlags, _) in
        guard let info = info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(evPathsRaw, to: NSArray.self) as? [String] ?? []
        for i in 0..<count {
            let flags = evFlags[i]
            let path = paths[i]
            let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let removed = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            guard isFile, !removed else { continue }
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard ["mp4","mov","m4v","mkv","avi","mts","m2ts","webm","wmv","flv","hevc","prores"].contains(ext) else { continue }
            Task { @MainActor in
                await watcher.indexer.indexFile(url)
            }
        }
    }
}
