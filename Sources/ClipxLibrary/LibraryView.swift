import SwiftUI
import GRDB

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sources: [Source] = []
    @State private var clips: [Clip] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let pid = appState.selectedProjectID {
                ProjectHeaderView(projectID: pid)
            }
            content
        }
        .onAppear(perform: reload)
        .onChange(of: appState.searchQuery) { _, _ in reload() }
        .onChange(of: appState.activeFilters) { _, _ in reload() }
        .onChange(of: appState.sortOption) { _, _ in reload() }
        .onChange(of: appState.libraryRevision) { _, _ in reload() }
        .onChange(of: appState.bootstrapped) { _, ready in if ready { reload() } }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search clips, tags, notes…", text: $appState.searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 360)

            Spacer()

            Picker("", selection: $appState.sortOption) {
                ForEach(ClipSortOption.pickerCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            Picker("", selection: $appState.viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                Image(systemName: "calendar").tag(LibraryViewMode.calendar)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Grid · List · Calendar")

            Button {
                appState.inspectorVisible.toggle()
            } label: {
                Image(systemName: appState.inspectorVisible ? "sidebar.trailing" : "sidebar.right")
                    .foregroundStyle(appState.inspectorVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle Inspector (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sources.isEmpty && clips.isEmpty {
            EmptyLibraryView()
        } else {
            switch appState.viewMode {
            case .grid:
                ClipGridView(sources: sources, clips: clips)
            case .list:
                ClipListView(sources: sources, clips: clips)
            case .calendar:
                CalendarBrowseView(sources: sources)
            }
        }
    }

    private func reload() {
        loading = true
        NSLog("[Clipx] LibraryView.reload() called")
        Task.detached(priority: .userInitiated) {
            let env = AppEnvironment.shared
            guard let database = env.database, let search = env.searchEngine else {
                NSLog("[Clipx] reload: env not ready, bailing")
                await MainActor.run { self.loading = false }
                return
            }
            // Fetch sources and clips independently so a failure in one doesn't
            // hide the other.
            var fetchedSources: [Source] = []
            var fetchedClips: [Clip] = []
            do {
                let sortSQL = LibraryView.sourcesOrderBy(AppState.shared.sortOption)
                fetchedSources = try database.read { db in
                    try Source.fetchAll(db, sql: "SELECT * FROM sources ORDER BY \(sortSQL) LIMIT 500")
                }
                NSLog("[Clipx] reload: fetched %d sources", fetchedSources.count)
            } catch {
                NSLog("[Clipx] reload: sources query failed: %@", String(describing: error))
            }
            do {
                fetchedClips = try search.search(
                    query: AppState.shared.searchQuery,
                    filters: AppState.shared.activeFilters,
                    sort: AppState.shared.sortOption
                )
                NSLog("[Clipx] reload: fetched %d clips", fetchedClips.count)
            } catch {
                NSLog("[Clipx] reload: clips search failed: %@", String(describing: error))
            }
            let finalSources = fetchedSources
            let finalClips = fetchedClips
            await MainActor.run {
                self.sources = finalSources
                self.clips = finalClips
                self.loading = false
                NSLog("[Clipx] reload: state updated, sources=%d clips=%d", finalSources.count, finalClips.count)
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
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.title3)
            Text("Add a folder of videos to get started.")
                .foregroundStyle(.secondary)
            Button("Add Folder…") {
                Task { @MainActor in await ImportCoordinator.shared.pickFolder() }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
