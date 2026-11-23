import SwiftUI
import GRDB

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sources: [Source] = []
    @State private var clips: [Clip] = []
    @State private var loading = false
    @State private var hitLimit = false
    @State private var resultLimit = 500
    @State private var reloadTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var loadError: String?

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
            if let loadError, !sources.isEmpty || !clips.isEmpty {
                HStack(spacing: 8) {
                    Label("Refresh failed. Showing previous results.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                        .help(loadError)
                    Spacer()
                    Button("Try again") { reload() }.controlSize(.small)
                }
                .padding(10)
                .background(Theme.bgRaised)
            }
            content
        }
        .background(Theme.bg)
        .onAppear { reload() }
        // Search debounced — every other change reloads immediately.
        .onChange(of: appState.searchQuery) { _, _ in scheduleDebouncedReload() }
        .onChange(of: appState.activeFilters) { _, _ in resetAndReload() }
        .onChange(of: appState.sortOption) { _, _ in resetAndReload() }
        .onChange(of: appState.libraryRevision) { _, _ in reload() }
        .onChange(of: appState.bootstrapped) { _, ready in if ready { reload() } }
        .onDisappear { searchReloadTask?.cancel(); reloadTask?.cancel(); loadGeneration = UUID() }
        .overlay(alignment: .topTrailing) {
            if loading && (!sources.isEmpty || !clips.isEmpty) { ProgressView().controlSize(.small).padding(10) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.bootstrapped {
            ProgressView("Opening library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.viewMode == .lightTable {
            // The Light Table harvests all purposed clips itself, independent of
            // the current search/filter narrowing.
            LightTableView()
        } else if loading && sources.isEmpty && clips.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, sources.isEmpty && clips.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load your library", systemImage: "exclamationmark.triangle")
            } description: { Text(loadError) } actions: { Button("Try again") { reload() } }
        } else if sources.isEmpty && clips.isEmpty {
            if isFiltering {
                NoResultsView {                    // per-query no-results (#38)
                    appState.searchQuery = ""
                    appState.clearFilters()
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
                    CalendarBrowseView(sources: sources, clips: clips)
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
            Text("Showing \(sources.count) sources and \(clips.count) clips")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Load more") { resultLimit += Self.sourcesLimit; reload() }
                .disabled(loading)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.bgRaised)
    }

    private func scheduleDebouncedReload() {
        reloadTask?.cancel()
        loadGeneration = UUID()
        searchReloadTask?.cancel()
        searchReloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.searchDebounceMs)
            guard !Task.isCancelled else { return }
            resetAndReload()
        }
    }

    private func resetAndReload() {
        resultLimit = Self.sourcesLimit
        reload()
    }

    private func reload() {
        reloadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        guard let search = AppEnvironment.shared.searchEngine else { loading = false; return }
        let query = appState.searchQuery
        let filters = appState.activeFilters
        let sort = appState.sortOption
        let limit = resultLimit
        loading = true
        reloadTask = Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let sources = try search.searchSources(query: query, filters: filters, sort: sort, limit: limit + 1)
                    let clips = try search.search(query: query, filters: filters, sort: sort, limit: limit + 1)
                    return (sources, clips)
                }.value
                guard !Task.isCancelled, loadGeneration == generation else { return }
                sources = Array(result.0.prefix(limit))
                clips = Array(result.1.prefix(limit))
                hitLimit = result.0.count > limit || result.1.count > limit
                loadError = nil
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                loadError = error.localizedDescription
                if !sources.isEmpty || !clips.isEmpty {
                    appState.showToast("Couldn't refresh library: \(error.localizedDescription)", level: .error)
                }
            }
            loading = false
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
