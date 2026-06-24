import SwiftUI
import GRDB

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sources: [Source] = []
    @State private var clips: [Clip] = []
    @State private var loading = false
    @State private var hitLimit = false

    /// True when a query or filter is narrowing the library — distinguishes a
    /// "no results" state from a genuinely empty library. (#38)
    private var isFiltering: Bool {
        !appState.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || appState.activeFilters.isActive
    }
    /// Cancellable reload task so a flurry of keystrokes only fires one query.
    @State private var searchReloadTask: Task<Void, Never>?

    /// Page size for the sources query — surfaced in UI when hit so the user
    /// knows there's more behind a "Load more" button.
    private static let sourcesLimit: Int = 500
    /// Debounce interval (ms) between the last keystroke and search reload.
    private static let searchDebounceMs: UInt64 = 200_000_000 // 200ms

    var body: some View {
        VStack(spacing: 0) {
            if let pid = appState.selectedProjectID {
                ProjectHeaderView(projectID: pid)
                Divider().overlay(Theme.border)
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
    private var content: some View {
        if appState.viewMode == .lightTable {
            // The Light Table harvests all purposed clips itself, independent of
            // the current search/filter narrowing.
            LightTableView()
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sources.isEmpty && clips.isEmpty {
            if isFiltering {
                NoResultsView {                    // per-query no-results (#38)
                    appState.searchQuery = ""
                    appState.activeFilters = ClipFilters()
                }
            } else {
                EmptyLibraryView()
            }
        } else {
            VStack(spacing: 0) {
                switch appState.viewMode {
                case .grid:
                    ClipGridView(sources: sources, clips: clips)
                case .list:
                    ClipListView(sources: sources, clips: clips)
                case .calendar:
                    CalendarBrowseView(sources: sources)
                case .lightTable:
                    EmptyView()   // handled above, before the empty-state guard
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
                // Narrow the sources by the same query/filters as the clips —
                // previously every source stayed on screen regardless. (#28)
                let (whereSQL, whereArgs) = LibraryView.sourcesWhere(
                    query: AppState.shared.searchQuery,
                    filters: AppState.shared.activeFilters
                )
                var args = whereArgs
                args.append(Int64(Self.sourcesLimit))
                fetchedSources = try database.read { db in
                    try Source.fetchAll(
                        db,
                        sql: "SELECT * FROM sources \(whereSQL) ORDER BY \(sortSQL) LIMIT ?",
                        arguments: StatementArguments(args)
                    )
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

    /// Builds the WHERE clause that narrows the sources grid by the active query
    /// and filters, matching how clips are filtered. (#28)
    private static func sourcesWhere(query: String, filters: ClipFilters) -> (String, [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            clauses.append("LOWER(path) LIKE ? ESCAPE '\\'")
            args.append("%\(sqlLikeEscape(q.lowercased()))%")
        }
        if let from = filters.dateFrom {
            clauses.append("COALESCE(created_at, imported_at) >= ?")
            args.append(Int64(from.timeIntervalSince1970))
        }
        if let to = filters.dateTo {
            clauses.append("COALESCE(created_at, imported_at) <= ?")
            args.append(Int64(to.timeIntervalSince1970))
        }
        if filters.onlineOnly { clauses.append("online = 1") }
        // Clip-attribute filters can't match whole sources; when one is active
        // hide sources so the view focuses on the matching clips.
        let clipOnly = !filters.moods.isEmpty || !filters.shotTypes.isEmpty
            || !filters.cameraMoves.isEmpty || !filters.settings.isEmpty
            || !filters.colorLabels.isEmpty || filters.minRating > 0 || filters.unusedOnly
            || !filters.projectIDs.isEmpty || !filters.collectionIDs.isEmpty
        if clipOnly { clauses.append("1 = 0") }
        let sql = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (sql, args)
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

/// Shown when a query/filter matches nothing in a non-empty library. (#38)
private struct NoResultsView: View {
    let onClear: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("No matches")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Nothing matches your search and filters.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button("Clear search & filters", action: onClear)
                .buttonStyle(PillButtonStyle(kind: .ghost))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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
