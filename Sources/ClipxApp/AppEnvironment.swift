import Foundation
import GRDB
import OSLog

/// Owns the database, indexer, watcher, thumbnail engine, and export pipeline.
/// All services are nil before `bootstrap()` runs to completion. If bootstrap
/// fails partway, every property is rolled back to nil and `AppState.bootstrapError`
/// is set so the UI can surface an alert.
///
/// Not @MainActor — services are thread-safe and the singleton is read from
/// background contexts (drag-drop, export pipeline). Bootstrap itself is @MainActor.
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    private(set) var database: Database?
    private(set) var indexer: Indexer?
    private(set) var watcher: FolderWatcher?
    private(set) var thumbnailEngine: ThumbnailEngine?
    private(set) var exportPipeline: ExportPipeline?
    private(set) var markerStore: MarkerStore?
    private(set) var tagStore: TagStore?
    private(set) var bookmarkStore: BookmarkStore?
    private(set) var searchEngine: SearchEngine?
    /// Transcodes + caches small web proxies so the browser streams a
    /// compressed version instead of the raw multi-Mbps source file.
    private(set) var webProxyEngine: WebProxyEngine?
    /// Embedded HTTP server that powers the phone/laptop web UI on the
    /// local network. Optional — disabled by user setting kills the listener.
    private(set) var httpServer: HTTPServer?

    private var didBootstrap = false

    private init() {}

    @MainActor
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        ClipxLog.app.info("bootstrap: starting")

        do {
            let db = try Database.open()
            let bookmarks = BookmarkStore(database: db)
            let markers = MarkerStore(database: db)
            let tags = TagStore(database: db)
            let search = SearchEngine(database: db)
            let thumbs = ThumbnailEngine(database: db)
            let idx = Indexer(database: db, thumbnailEngine: thumbs)
            let watch = FolderWatcher(indexer: idx, bookmarkStore: bookmarks)
            let exports = ExportPipeline(database: db)

            // All services constructed; publish them atomically.
            self.database = db
            self.bookmarkStore = bookmarks
            self.markerStore = markers
            self.tagStore = tags
            self.searchEngine = search
            self.thumbnailEngine = thumbs
            self.indexer = idx
            self.watcher = watch
            self.exportPipeline = exports
            self.webProxyEngine = WebProxyEngine()

            ClipxLog.app.info("bootstrap: DB + services initialized")
            AppState.shared.bootstrapped = true
            AppState.shared.libraryRevision &+= 1

            watch.resumeAll()

            // Close out any export the previous run was killed mid-flight, so no
            // record is stuck "in progress" forever. (#17)
            ExportPipeline.reconcileInterruptedExports(database: db)

            // Offline any sources whose files vanished while closed, and repair
            // the search index if it desynced. (#21, #25)
            Task.detached {
                _ = await idx.reconcileMissingSources()
                search.verifyAndRepairIndex()
            }

            // One-time: derive recording dates from filenames for footage that
            // indexed without a usable created_at (DJI / action-cam files whose
            // filesystem date is the copy date, not the shoot date). Fixes the
            // calendar's "No recording date" bucket for the existing library.
            if !UserDefaults.standard.bool(forKey: "filenameDateBackfillV1") {
                Task.detached {
                    let n = await idx.backfillFilenameDates()
                    UserDefaults.standard.set(true, forKey: "filenameDateBackfillV1")
                    if n > 0 { ClipxLog.app.info("filename date backfill updated \(n) sources") }
                }
            }

            // Background-prime thumbnails for any source missing one. Without
            // this, blank cards stay blank until the user scrolls them into
            // view (LazyVGrid's onAppear is the only trigger). Runs at low
            // priority so it doesn't fight UI work.
            thumbs.primeMissingThumbnails()

            // Start the embedded HTTP server (phone/laptop web UI) if the
            // user has it enabled. Default is OFF — turning it on is a
            // deliberate user choice in Settings.
            if UserDefaults.standard.bool(forKey: "webServerEnabled") {
                startWebServer()
            }

            ClipxLog.app.info("bootstrap: complete")
        } catch {
            // Roll back so half-initialized state can't be observed.
            self.database = nil
            self.bookmarkStore = nil
            self.markerStore = nil
            self.tagStore = nil
            self.searchEngine = nil
            self.thumbnailEngine = nil
            self.indexer = nil
            self.watcher = nil
            self.exportPipeline = nil
            self.webProxyEngine = nil
            didBootstrap = false
            ClipxLog.app.error("bootstrap FAILED: \(String(describing: error), privacy: .public)")
            AppState.shared.bootstrapError = error.localizedDescription
        }
    }

    @MainActor
    func shutdown() {
        watcher?.stopAll()
        exportPipeline?.cancelAll()
        httpServer?.stop()
        httpServer = nil
    }

    /// Spins up the embedded web server. Called at bootstrap (when the
    /// `webServerEnabled` default is true) and from Settings when the user
    /// flips the toggle.
    @MainActor
    func startWebServer() {
        guard httpServer == nil else { return }
        let port = UInt16(UserDefaults.standard.integer(forKey: "webServerPort"))
        let server = HTTPServer(port: port == 0 ? 7878 : port)
        do {
            try server.start { request in
                await ClipxRoutes.handle(request)
            }
            httpServer = server
            ClipxLog.app.info("web server started on port \(server.port)")
            AppState.shared.showToast(
                "Web UI live at http://\(Self.preferredLocalAddress() ?? "<this mac>"):\(server.port)",
                level: .info
            )
        } catch {
            ClipxLog.app.error("web server failed to start: \(String(describing: error), privacy: .public)")
            AppState.shared.showToast("Web server failed: \(error.localizedDescription)", level: .error)
        }
    }

    @MainActor
    func stopWebServer() {
        httpServer?.stop()
        httpServer = nil
    }

    /// Best-effort: returns the first non-loopback IPv4 address the Mac is
    /// reachable on. Used to show the user a "http://192.168.1.x:7878" URL
    /// in Settings. Returns nil if we can't enumerate (no network).
    static func preferredLocalAddress() -> String? {
        var addr = ifaddrs()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            addr = cur.pointee
            if let sa = addr.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let name = String(cString: addr.ifa_name)
                // Prefer en0/en1 (typical Wi-Fi / Ethernet) over utun, lo0,
                // awdl, llw — pickier than "first non-loopback" to avoid
                // returning unreachable VPN addresses.
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                                   socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let result = String(cString: host)
                        if !result.hasPrefix("127.") { return result }
                    }
                }
            }
            ptr = addr.ifa_next
        }
        return nil
    }
}
