import Foundation
import GRDB

/// The "wiring" of the app — owns the database, indexer, watcher,
/// thumbnail engine, and export pipeline. Constructed once at launch.
/// Not @MainActor — its dependencies are thread-safe, and the singleton
/// is read from background contexts (drag-drop, export pipeline).
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    private(set) var database: Database!
    private(set) var indexer: Indexer!
    private(set) var watcher: FolderWatcher!
    private(set) var thumbnailEngine: ThumbnailEngine!
    private(set) var exportPipeline: ExportPipeline!
    private(set) var markerStore: MarkerStore!
    private(set) var tagStore: TagStore!
    private(set) var bookmarkStore: BookmarkStore!
    private(set) var searchEngine: SearchEngine!

    private var didBootstrap = false

    private init() {}

    @MainActor
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            database = try Database.open()
            bookmarkStore = BookmarkStore(database: database)
            markerStore = MarkerStore(database: database)
            tagStore = TagStore(database: database)
            searchEngine = SearchEngine(database: database)
            thumbnailEngine = ThumbnailEngine(database: database)
            indexer = Indexer(database: database, thumbnailEngine: thumbnailEngine)
            watcher = FolderWatcher(indexer: indexer, bookmarkStore: bookmarkStore)
            exportPipeline = ExportPipeline(database: database)

            // Restore folder access from security-scoped bookmarks and resume watching
            watcher.resumeAll()
        } catch {
            // Surface bootstrap failure clearly. We don't ship a crash here —
            // we expose it via a banner so the user can recover by re-picking
            // their library folder.
            NSLog("Clipx bootstrap failed: \(error)")
        }
    }

    @MainActor
    func shutdown() {
        watcher?.stopAll()
        exportPipeline?.cancelAll()
    }
}
