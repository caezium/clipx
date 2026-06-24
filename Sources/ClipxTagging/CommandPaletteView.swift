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
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Type a command, clip name, or tag…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($fieldFocused)
                        .onSubmit { runSelected() }
                }
                .padding(16)
                Divider().overlay(Theme.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                                let isSelected = idx == selectedIndex
                                Button {
                                    selectedIndex = idx
                                    runSelected()
                                } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 13))
                                            .frame(width: 18)
                                            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                                        Text(item.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        if let hint = item.shortcut {
                                            Text(hint)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isSelected ? Theme.accentSoft : .clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                                .padding(.horizontal, 6)
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.r3))
            .background(Theme.bgRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.r3))
            .overlay(RoundedRectangle(cornerRadius: Theme.r3).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
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
        let commands = staticCommands()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            results = commands
            return
        }
        // Subsequence match (each query char in order) ranks better than raw
        // `.contains` while staying allocation-light.
        let matchedCommands = commands
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = subsequenceScore(of: q, in: item.title.lowercased()) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 < $1.1 } // lower = tighter match
            .map(\.0)
        // The placeholder promises "clip name, or tag" — actually search them.
        results = matchedCommands + clipResults(for: q)
    }

    /// The fixed action commands. Order here is the default (empty-query) order.
    private func staticCommands() -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.append(PaletteItem(id: "add-folder", title: "Add Folder…", icon: "folder.badge.plus", shortcut: "⌘O") {
            Task { @MainActor in await ImportCoordinator.shared.pickFolder() }
        })
        items.append(PaletteItem(id: "rescan", title: "Rescan Library Folders", icon: "arrow.clockwise", shortcut: "⌘R") {
            AppEnvironment.shared.watcher?.rescanAll()
        })
        items.append(PaletteItem(id: "view-calendar", title: "Calendar View", icon: "calendar") {
            appState.playerSourceID = nil; appState.viewMode = .calendar
        })
        items.append(PaletteItem(id: "view-grid", title: "Grid View", icon: "square.grid.2x2") {
            appState.playerSourceID = nil; appState.viewMode = .grid
        })
        items.append(PaletteItem(id: "view-list", title: "List View", icon: "list.bullet") {
            appState.playerSourceID = nil; appState.viewMode = .list
        })
        items.append(PaletteItem(id: "view-lighttable", title: "Light Table — clips by purpose", icon: "tray.full") {
            appState.playerSourceID = nil; appState.viewMode = .lightTable
        })
        items.append(PaletteItem(id: "toggle-inspector", title: "Toggle Inspector", icon: "sidebar.trailing", shortcut: "⌥⌘I") {
            appState.inspectorVisible.toggle()
        })
        items.append(PaletteItem(id: "all-clips", title: "Show All Clips", icon: "rectangle.stack") {
            appState.activeFilters = ClipFilters()
            appState.selectedProjectID = nil
            appState.selectedCollectionID = nil
        })
        items.append(PaletteItem(id: "unused", title: "Show Unused Clips", icon: "sparkles") {
            var f = ClipFilters(); f.unusedOnly = true
            appState.activeFilters = f
            appState.selectedProjectID = nil
        })
        items.append(PaletteItem(id: "export-reels", title: "Export Selected as Reels", icon: "square.and.arrow.up", shortcut: "⇧⌘R") {
            ExportActions.exportSelected(.reels)
        })
        items.append(PaletteItem(id: "export-yt-1080", title: "Export YouTube 1080p", icon: "play.rectangle") {
            ExportActions.exportSelected(.youtube1080p)
        })
        items.append(PaletteItem(id: "export-fcpxml", title: "Export FCPXML…", icon: "film.stack") {
            ExportActions.exportFCPXML()
        })
        items.append(PaletteItem(id: "export-obsidian", title: "Write Obsidian Sidecars…", icon: "doc.text.below.ecg") {
            ExportActions.exportObsidian()
        })
        items.append(PaletteItem(id: "settings", title: "Settings…", icon: "gearshape", shortcut: "⌘,") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        return items
    }

    /// Live clip matches from the FTS search engine — selecting one opens it in
    /// the player. This is what makes the palette a navigation tool, not just a
    /// command list.
    private func clipResults(for query: String) -> [PaletteItem] {
        guard let search = AppEnvironment.shared.searchEngine else { return [] }
        let clips = (try? search.search(query: query, filters: ClipFilters(), sort: .nameAsc, limit: 8)) ?? []
        return clips.prefix(8).map { clip in
            PaletteItem(
                id: "clip-\(clip.id ?? 0)",
                title: clip.name ?? "Clip #\(clip.id ?? 0)",
                icon: "scissors",
                shortcut: PlayerController.formatMs(clip.outMs - clip.inMs)
            ) { openClip(clip) }
        }
    }

    private func openClip(_ clip: Clip) {
        if let id = clip.id { appState.selectedClipIDs = [id] }
        appState.playerSourceID = clip.sourceID
        appState.playerInMs = clip.inMs
        appState.playerOutMs = clip.outMs
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
