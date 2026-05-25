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

            ClipxLog.app.info("bootstrap: DB + services initialized")
            AppState.shared.bootstrapped = true
            AppState.shared.libraryRevision &+= 1

            watch.resumeAll()
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
            didBootstrap = false
            ClipxLog.app.error("bootstrap FAILED: \(String(describing: error), privacy: .public)")
            AppState.shared.bootstrapError = error.localizedDescription
        }
    }

    @MainActor
    func shutdown() {
        watcher?.stopAll()
        exportPipeline?.cancelAll()
    }
}
