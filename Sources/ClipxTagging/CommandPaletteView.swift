import SwiftUI

/// Cmd+K command palette — Raycast-style fuzzy search over actions, clips,
/// tags, and collections.
struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String = ""
    @State private var results: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { appState.commandPaletteOpen = false }
            VStack(spacing: 0) {
                TextField("Type a command, clip name, or tag…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(16)
                    .focused($fieldFocused)
                    .onSubmit { runFirst() }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { item in
                            Button { item.run(); appState.commandPaletteOpen = false } label: {
                                HStack {
                                    Image(systemName: item.icon)
                                    Text(item.title)
                                    Spacer()
                                    if let hint = item.shortcut {
                                        Text(hint).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 640, height: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            .shadow(radius: 24)
        }
        .onAppear {
            fieldFocused = true
            reload()
        }
        .onChange(of: query) { _, _ in reload() }
        .onKeyPress(.escape) {
            appState.commandPaletteOpen = false
            return .handled
        }
    }

    private func reload() {
        var items: [PaletteItem] = []
        items.append(PaletteItem(
            id: "add-folder", title: "Add Folder…", icon: "folder.badge.plus", shortcut: "⌘O"
        ) { Task { @MainActor in await ImportCoordinator.shared.pickFolder() } })
        items.append(PaletteItem(
            id: "export-reels", title: "Export Selected as Reels", icon: "square.and.arrow.up", shortcut: "⇧⌘R"
        ) { ExportActions.exportSelected(.reels) })
        items.append(PaletteItem(
            id: "export-yt-1080", title: "Export YouTube 1080p", icon: "play.rectangle"
        ) { ExportActions.exportSelected(.youtube1080p) })
        items.append(PaletteItem(
            id: "export-fcpxml", title: "Export FCPXML…", icon: "film.stack"
        ) { ExportActions.exportFCPXML() })
        items.append(PaletteItem(
            id: "export-obsidian", title: "Write Obsidian Sidecars…", icon: "doc.text.below.ecg"
        ) { ExportActions.exportObsidian() })

        // Filter by query.
        let q = query.lowercased()
        if q.isEmpty {
            results = items
        } else {
            results = items.filter { $0.title.lowercased().contains(q) }
        }
    }

    private func runFirst() {
        if let first = results.first {
            first.run()
            appState.commandPaletteOpen = false
        }
    }
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let run: () -> Void

    init(id: String, title: String, icon: String, shortcut: String? = nil, run: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.run = run
    }
}
