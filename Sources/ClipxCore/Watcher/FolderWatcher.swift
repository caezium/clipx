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
    private var work: Task<Void, Never>?
    private var pendingEvents: [String: Event] = [:]
    private var generation = 0

    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId

        var requiresRescan: Bool {
            let mask = UInt32(kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped |
                kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
            return flags & mask != 0
        }
    }
    /// Last event id observed by the callback. Used so a stream
    /// restart (add/remove folder) doesn't drop events that arrived in the
    /// gap — without this, every restart used `kFSEventStreamEventIdSinceNow`.
    private var lastSeenEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    /// Persisted so the stream resumes from where it left off across launches,
    /// replaying changes (incl. deletions) that happened while closed. (#26)
    private static let eventIdKey = "folderWatcherLastEventIdV1"

    init(indexer: Indexer, bookmarkStore: BookmarkStore) {
        self.indexer = indexer
        self.bookmarkStore = bookmarkStore
        if let saved = AppPreferences.defaults.string(forKey: Self.eventIdKey), let v = UInt64(saved) {
            self.lastSeenEventId = FSEventStreamEventId(v)
        }
    }

    /// Restores access to all stored library folders and starts a watcher
    /// covering them. Called at app launch from `AppEnvironment.bootstrap()`.
    func resumeAll() {
        stopStream()
        cancelWork()
        let urls = bookmarkStore.resumeAccess()
        paths = uniquePaths(from: urls.map(\.path))
        restartStream()
        scan(urls, announce: false)
        if !bookmarkStore.accessFailures.isEmpty {
            AppState.shared.showToast("Some library folders are unavailable. Reconnect the drive or add the folder again in Settings.", level: .warning)
        }
    }

    @discardableResult
    func add(folder url: URL) -> Bool {
        do {
            try bookmarkStore.addFolder(url: url)
            if !paths.contains(url.path) { paths.append(url.path) }
            restartStream()
            scan([url], announce: true)
            return true
        } catch {
            AppState.shared.showToast("Could not add folder: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func remove(folderPath path: String) {
        guard bookmarkStore.removeFolder(path: path) else {
            AppState.shared.showToast("Could not remove the folder. Try again.", level: .error)
            return
        }
        paths.removeAll { $0 == path }
        cancelWork()
        restartStream()
        scan(paths.map { URL(fileURLWithPath: $0) }, announce: false)
    }

    func rescanAll() {
        let urls = bookmarkStore.resumeAccess()
        paths = uniquePaths(from: urls.map(\.path))
        restartStream()
        guard !urls.isEmpty else {
            let message = bookmarkStore.allFolders().isEmpty
                ? "Add a library folder in Settings to start indexing."
                : "Library folders are unavailable. Reconnect the drive or add the folder again in Settings."
            AppState.shared.showToast(message, level: .warning)
            return
        }
        scan(urls, announce: true)
    }

    private func scan(_ urls: [URL], announce: Bool) {
        guard !urls.isEmpty else { return }
        if announce { AppState.shared.showToast("Scanning library folders…", level: .info) }
        let previous = work
        let scanGeneration = generation
        work = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, scanGeneration == self.generation else { return }
            var total = Indexer.ScanResult()
            for url in urls {
                guard !Task.isCancelled, scanGeneration == self.generation else { return }
                let result = await self.indexer.index(folder: url)
                guard !result.cancelled, !Task.isCancelled, scanGeneration == self.generation else { return }
                total.scanned += result.scanned
                total.indexed += result.indexed
                total.failed += result.failed
                total.deferred += result.deferred
            }
            guard !Task.isCancelled, scanGeneration == self.generation else { return }
            if announce {
                let message = "Checked \(total.scanned) files; \(total.indexed) added or updated."
                if total.failed > 0 {
                    AppState.shared.showToast(message + " \(total.failed) could not be read; check folder access and try again.", level: .warning)
                } else if total.deferred > 0 {
                    AppState.shared.showToast(message + " \(total.deferred) still copying; indexing will retry automatically.", level: .info)
                } else {
                    AppState.shared.showToast(message, level: .success)
                }
            }
            AppState.shared.libraryRevision &+= 1
        }
    }

    func stopAll() {
        stopStream()
        cancelWork()
        bookmarkStore.stopAll()
    }

    private func cancelWork() {
        generation &+= 1
        work?.cancel()
        work = nil
        pendingEvents.removeAll()
        // Serialize cancellation ahead of subsequent scans on the indexer.
        let idx = indexer
        work = Task { await idx.cancelPendingWork() }
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func restartStream() {
        stopStream()
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
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
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
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            AppState.shared.showToast("Folder watching could not start. Use Rescan Library to refresh files.", level: .warning)
            return
        }
        self.stream = stream
    }

    private nonisolated func uniquePaths(from input: [String]) -> [String] {
        var seen = Set<String>()
        return input.filter { seen.insert($0).inserted }
    }

    private func receive(_ events: [Event]) {
        guard stream != nil else { return }
        for event in events {
            if let earlier = pendingEvents[event.path] {
                pendingEvents[event.path] = Event(path: event.path,
                    flags: earlier.flags | event.flags, id: max(earlier.id, event.id))
            } else { pendingEvents[event.path] = event }
        }
        let previous = work
        let eventGeneration = generation
        work = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, eventGeneration == self.generation else { return }
            let batch = Array(self.pendingEvents.values)
            self.pendingEvents.removeAll()
            guard !batch.isEmpty else { return }
            var completed = true
            if batch.contains(where: \.requiresRescan) {
                // Directory renames and dropped events require a full walk,
                // including missing-file reconciliation and bookmark relocation.
                let urls = self.bookmarkStore.resumeAccess()
                self.paths = self.uniquePaths(from: urls.map(\.path))
                self.restartStream()
                for url in urls {
                    guard !Task.isCancelled, eventGeneration == self.generation else { return }
                    let result = await self.indexer.index(folder: url)
                    guard !result.cancelled, !Task.isCancelled, eventGeneration == self.generation else { return }
                    completed = completed && result.failed == 0 && result.deferred == 0 && !result.cancelled
                }
            } else {
                for event in batch {
                    guard !Task.isCancelled, eventGeneration == self.generation else { return }
                    let path = self.libraryPath(for: event.path)
                    let url = URL(fileURLWithPath: path)
                    guard Indexer.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    if FileManager.default.fileExists(atPath: path) {
                        let done = await self.indexer.processFileEvent(url)
                        completed = completed && done
                    } else { await self.indexer.markPathOffline(path) }
                }
            }
            guard completed, !Task.isCancelled, eventGeneration == self.generation,
                  let maximum = batch.map(\.id).max() else { return }
            self.lastSeenEventId = maximum
            AppPreferences.defaults.set(String(maximum), forKey: Self.eventIdKey)
        }
    }

    private func libraryPath(for eventPath: String) -> String {
        // FSEvents reports POSIX canonical paths, including /private/var.
        // Foundation's resolvingSymlinksInPath deliberately shortens that
        // prefix, so use realpath to match the event and keep stored identity.
        for root in paths.sorted(by: { $0.count > $1.count }) {
            guard let resolved = realpath(root, nil) else { continue }
            let canonical = String(cString: resolved)
            free(resolved)
            if eventPath == canonical { return root }
            if eventPath.hasPrefix(canonical + "/") {
                return root + eventPath.dropFirst(canonical.count)
            }
        }
        return eventPath
    }

    nonisolated private static let callback: FSEventStreamCallback = {
        (_, info, count, evPathsRaw, evFlags, evIds) in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(evPathsRaw, to: NSArray.self) as? [String] ?? []
        // Copy C-owned memory before crossing the actor boundary.
        let events = (0..<min(count, paths.count)).map {
            Event(path: paths[$0], flags: evFlags[$0], id: evIds[$0])
        }
        Task { @MainActor in watcher.receive(events) }
    }
}
