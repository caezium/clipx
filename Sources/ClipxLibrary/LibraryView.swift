import SwiftUI
import GRDB

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sources: [Source] = []
    @State private var clips: [Clip] = []
    @State private var loading = false
    @State private var hitLimit = false
    /// Cancellable reload task so a flurry of keystrokes only fires one query.
    @State private var searchReloadTask: Task<Void, Never>?

    /// Page size for the sources query — surfaced in UI when hit so the user
    /// knows there's more behind a "Load more" button.
    private static let sourcesLimit: Int = 500
    /// Debounce interval (ms) between the last keystroke and search reload.
    private static let searchDebounceMs: UInt64 = 200_000_000 // 200ms

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if let pid = appState.selectedProjectID {
                ProjectHeaderView(projectID: pid)
            }
            content
        }
        .background(Theme.bg)
        .onAppear(perform: reload)
        // Search debounced — every other change reloads immediately.
        .onChange(of: appState.searchQuery) { _, _ in scheduleDebouncedReload() }
        .onChange(of: appState.activeFilters) { _, _ in reload() }
        .onChange(of: appState.sortOption) { _, _ in reload() }
        .onChange(of: appState.libraryRevision) { _, _ in reload() }
        .onChange(of: appState.bootstrapped) { _, ready in if ready { reload() } }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search clips, tags, notes…", text: $appState.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !appState.searchQuery.isEmpty {
                    Button { appState.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .frame(maxWidth: 380)

            Spacer()

            Picker("", selection: $appState.sortOption) {
                ForEach(ClipSortOption.pickerCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.textSecondary)
            .frame(width: 170)

            Picker("", selection: $appState.viewMode) {
                Image(systemName: "calendar").tag(LibraryViewMode.calendar)
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Calendar · Grid · List")

            Button {
                appState.inspectorVisible.toggle()
            } label: {
                Image(systemName: appState.inspectorVisible ? "sidebar.trailing" : "sidebar.right")
            }
            .buttonStyle(.plain)
            .clipxIconButton(active: appState.inspectorVisible)
            .help("Toggle Inspector (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.bgRaised)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sources.isEmpty && clips.isEmpty {
            EmptyLibraryView()
        } else {
            VStack(spacing: 0) {
                switch appState.viewMode {
                case .grid:
                    ClipGridView(sources: sources, clips: clips)
                case .list:
                    ClipListView(sources: sources, clips: clips)
                case .calendar:
                    CalendarBrowseView(sources: sources)
                }
                if hitLimit {
                    pageFooter
                }
            }
        }
    }

    private var pageFooter: some View {
        HStack {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Text("Showing first \(Self.sourcesLimit) sources — refine search or filters to see more.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.bgRaised)
    }

    private func scheduleDebouncedReload() {
        searchReloadTask?.cancel()
        searchReloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.searchDebounceMs)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func reload() {
        loading = true
        ClipxLog.library.debug("reload() called")
        Task.detached(priority: .userInitiated) {
            guard let database = AppEnvironment.shared.database,
                  let search = AppEnvironment.shared.searchEngine else {
                ClipxLog.library.debug("reload: env not ready, bailing")
                await MainActor.run { self.loading = false }
                return
            }
            var fetchedSources: [Source] = []
            var fetchedClips: [Clip] = []
            var truncated = false
            do {
                let sortSQL = LibraryView.sourcesOrderBy(AppState.shared.sortOption)
                fetchedSources = try database.read { db in
                    try Source.fetchAll(db, sql: "SELECT * FROM sources ORDER BY \(sortSQL) LIMIT ?", arguments: [Self.sourcesLimit])
                }
                // If we hit the limit, surface a footer so the user knows.
                if fetchedSources.count == Self.sourcesLimit {
                    let total = (try? database.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sources") ?? 0
                    }) ?? 0
                    truncated = total > Self.sourcesLimit
                }
                ClipxLog.library.debug("reload: fetched \(fetchedSources.count) sources")
            } catch {
                ClipxLog.library.error("reload: sources query failed: \(String(describing: error), privacy: .public)")
            }
            do {
                fetchedClips = try search.search(
                    query: AppState.shared.searchQuery,
                    filters: AppState.shared.activeFilters,
                    sort: AppState.shared.sortOption
                )
                ClipxLog.library.debug("reload: fetched \(fetchedClips.count) clips")
            } catch {
                ClipxLog.library.error("reload: clips search failed: \(String(describing: error), privacy: .public)")
            }
            let finalSources = fetchedSources
            let finalClips = fetchedClips
            let finalTruncated = truncated
            await MainActor.run {
                self.sources = finalSources
                self.clips = finalClips
                self.hitLimit = finalTruncated
                self.loading = false
            }
        }
    }

    /// Maps the user-selected sort option into a SQL ORDER BY clause for the
    /// sources table. "Newest / Oldest" uses the source's own recording date
    /// (`created_at`, pulled from file metadata) instead of the import date —
    /// you want to find the day you shot it, not the day you imported it.
    /// Imported-at is used as a fallback for sources whose metadata didn't
    /// produce a creation date.
    private static func sourcesOrderBy(_ sort: ClipSortOption) -> String {
        switch sort {
        case .sourceDateDesc, .dateImportedDesc:
            return "COALESCE(created_at, imported_at) DESC"
        case .sourceDateAsc, .dateImportedAsc:
            return "COALESCE(created_at, imported_at) ASC"
        case .importedDesc:
            return "imported_at DESC"
        case .importedAsc:
            return "imported_at ASC"
        case .durationDesc:
            return "COALESCE(duration_ms, 0) DESC"
        case .nameAsc:
            return "LOWER(path) ASC"
        case .ratingDesc:
            return "COALESCE(created_at, imported_at) DESC" // sources have no rating
        }
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("Your library is empty")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add a folder of footage to get started.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button("Add Folder…") {
                Task { @MainActor in await ImportCoordinator.shared.pickFolder() }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
