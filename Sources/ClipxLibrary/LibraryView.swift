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
            content
        }
        .onAppear(perform: reload)
        .onChange(of: appState.searchQuery) { _, _ in reload() }
        .onChange(of: appState.activeFilters) { _, _ in reload() }
        .onChange(of: appState.sortOption) { _, _ in reload() }
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
                ForEach(ClipSortOption.allCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            Picker("", selection: $appState.viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
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
            }
        }
    }

    private func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let env = await AppEnvironment.shared
            do {
                let fetchedSources: [Source] = try env.database.read { db in
                    try Source.order(Source.Columns.importedAt.desc).limit(500).fetchAll(db)
                }
                let fetchedClips: [Clip] = try await env.searchEngine.search(
                    query: AppState.shared.searchQuery,
                    filters: AppState.shared.activeFilters,
                    sort: AppState.shared.sortOption
                )
                await MainActor.run {
                    self.sources = fetchedSources
                    self.clips = fetchedClips
                    self.loading = false
                }
            } catch {
                await MainActor.run { self.loading = false }
            }
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
