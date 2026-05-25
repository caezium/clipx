import SwiftUI

/// Cmd+K command palette. Up/Down arrows navigate the result list,
/// Return runs the selected item, Esc dismisses.
struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String = ""
    @State private var results: [PaletteItem] = []
    @State private var selectedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                TextField("Type a command, clip name, or tag…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(16)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                                let isSelected = idx == selectedIndex
                                Button {
                                    selectedIndex = idx
                                    runSelected()
                                } label: {
                                    HStack {
                                        Image(systemName: item.icon)
                                        Text(item.title)
                                        Spacer()
                                        if let hint = item.shortcut {
                                            Text(hint).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, new in
                        if results.indices.contains(new) {
                            proxy.scrollTo(results[new].id, anchor: .center)
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
        .onChange(of: query) { _, _ in
            reload()
            selectedIndex = 0
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !results.isEmpty {
                selectedIndex = min(selectedIndex + 1, results.count - 1)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) {
            appState.commandPaletteOpen = false
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

        let q = query.lowercased()
        if q.isEmpty {
            results = items
        } else {
            // Subsequence match (each query char in order) ranks better than
            // raw substring `.contains` while staying allocation-light.
            results = items
                .compactMap { item -> (PaletteItem, Int)? in
                    guard let score = subsequenceScore(of: q, in: item.title.lowercased()) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 < $1.1 } // lower = tighter match
                .map(\.0)
        }
    }

    private func runSelected() {
        guard results.indices.contains(selectedIndex) else {
            results.first?.run()
            dismiss()
            return
        }
        results[selectedIndex].run()
        dismiss()
    }

    /// Returns a "distance" score for a subsequence match, or nil if not a
    /// match. Smaller is better — exact prefix scores ~0, scattered match
    /// scores high.
    private func subsequenceScore(of needle: String, in haystack: String) -> Int? {
        var n = needle.startIndex
        var lastFoundAt = haystack.startIndex
        var score = 0
        for i in haystack.indices {
            if n == needle.endIndex { break }
            if haystack[i] == needle[n] {
                if i > lastFoundAt {
                    score += haystack.distance(from: lastFoundAt, to: i)
                }
                lastFoundAt = haystack.index(after: i)
                n = needle.index(after: n)
            }
        }
        return n == needle.endIndex ? score : nil
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
