import SwiftUI
import GRDB

/// The harvest surface. Every marked clip, grouped by the *purpose* you gave it
/// (Coach / Reel / Publish…), each group with a goal-first export. This is where
/// find→mark→tag pays off: the decision you already made drives the export, so
/// you never think in resolutions.
struct LightTableView: View {
    @EnvironmentObject private var appState: AppState
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var loading = false
    @State private var loadError: String?
    @State private var clipsByPurpose: [String: [Clip]] = [:]

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if clipsByPurpose.isEmpty && loading {
                    ProgressView("Loading clips…").frame(maxWidth: .infinity, minHeight: 320)
                } else if let loadError, clipsByPurpose.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load Light Table", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: { Button("Try again", action: load) }
                } else if clipsByPurpose.isEmpty {
                    emptyState
                } else {
                    ForEach(orderedKeys, id: \.self) { key in
                        if let clips = clipsByPurpose[key], !clips.isEmpty {
                            purposeSection(key: key, clips: clips)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .onAppear(perform: load)
        .onChange(of: appState.libraryRevision) { _, _ in load() }
        // Honour the sidebar's library scope, like the grid/list views do.
        .onChange(of: appState.activeFilters) { _, _ in load() }
        .onChange(of: appState.searchQuery) { _, _ in load() }
        .onChange(of: appState.bootstrapped) { _, ready in if ready { load() } }
        .onDisappear { loadTask?.cancel(); loadGeneration = UUID() }
        .overlay(alignment: .topTrailing) { if loading { ProgressView().controlSize(.small).padding(10) } }
    }

    /// Active labels first (in preset order), then any leftover keys that exist
    /// in the data but aren't in the current active set (e.g. after a preset
    /// switch) so nothing tagged ever disappears.
    private var orderedKeys: [String] {
        let active = Purposes.active.map(\.key)
        let extras = clipsByPurpose.keys.filter { !active.contains($0) }.sorted()
        return active + extras
    }

    @ViewBuilder
    private func purposeSection(key: String, clips: [Clip]) -> some View {
        let preset = Self.suggestedPreset(forPurpose: key)
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    purposeTitle(key: key, count: clips.count)
                    Spacer(minLength: 8)
                    purposeActions(key: key, clips: clips, preset: preset, compact: false)
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        purposeTitle(key: key, count: clips.count)
                        Spacer(minLength: 4)
                        Text(preset.displayName).font(.caption).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    purposeActions(key: key, clips: clips, preset: preset, compact: true)
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(clips) { clip in
                    ClipCardView(
                        clip: clip,
                        isSelected: clip.id.map { appState.selectedClipIDs.contains($0) } ?? false,
                        onSelect: { selectSingle(clip) },
                        onToggle: { toggle(clip) },
                        onOpenInPlayer: { openInPlayer(clip) }
                    )
                    .draggable(ClipTransferable(clipID: clip.id ?? 0, preset: preset))
                }
            }
        }
    }

    private func purposeTitle(key: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Purposes.symbol(forKey: key))
                .font(.system(size: 13)).foregroundStyle(Theme.accent)
            Text(Purposes.title(forKey: key))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Theme.surface, in: Capsule()).foregroundStyle(Theme.textSecondary)
        }
        .fixedSize()
    }

    private func purposeActions(key: String, clips: [Clip], preset: ExportPreset, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await StintBridge.sendToReview(clipIDs: clips.compactMap(\.id), projectName: "\(Purposes.title(forKey: key)) — Clipx") }
            } label: { Label("Send to review", systemImage: "paperplane") }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .help("Share these clips in Stint for frame-pinned comments")
            Button {
                ExportActions.export(clipIDs: clips.compactMap(\.id), preset: preset)
            } label: {
                Label(compact ? "Export \(clips.count)" : "Export \(clips.count) · \(preset.displayName)", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PillButtonStyle(kind: .accent, compact: true))
            .help("Export \(clips.count) clips as \(preset.displayName)")
        }
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text(appState.activeFilters.isActive || !appState.searchQuery.isEmpty ? "No matching clips" : "Nothing tagged yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(appState.activeFilters.isActive || !appState.searchQuery.isEmpty
                 ? "No clips with a purpose match your search and filters."
                 : "Mark a clip and choose a purpose — it lands here, ready to export.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 360)
            if appState.activeFilters.isActive || !appState.searchQuery.isEmpty {
                Button("Clear search & filters") { appState.searchQuery = ""; appState.clearFilters() }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func selectSingle(_ clip: Clip) {
        guard let id = clip.id else { return }
        appState.selectedClipIDs = [id]
        if !appState.inspectorVisible { appState.inspectorVisible = true }
    }

    private func toggle(_ clip: Clip) {
        guard let id = clip.id else { return }
        if appState.selectedClipIDs.contains(id) { appState.selectedClipIDs.remove(id) }
        else { appState.selectedClipIDs.insert(id) }
    }

    private func openInPlayer(_ clip: Clip) {
        appState.openClip(clip)
    }

    private func load() {
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        guard let search = AppEnvironment.shared.searchEngine else { return }
        let filters = appState.activeFilters
        let query = appState.searchQuery
        loading = true
        loadTask = Task { @MainActor in
            do {
                let buckets = try await Task.detached(priority: .userInitiated) {
                    let clips = try search.search(query: query, filters: filters, sort: .ratingDesc)
                    var buckets: [String: [Clip]] = [:]
                    for clip in clips {
                        for key in clip.purposeList { buckets[key, default: []].append(clip) }
                    }
                    return buckets
                }.value
                guard !Task.isCancelled, loadGeneration == generation else { return }
                clipsByPurpose = buckets
                loadError = nil
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                loadError = error.localizedDescription
                appState.showToast("Couldn't load Light Table: \(error.localizedDescription)", level: .error)
            }
            loading = false
        }
    }

    /// Maps a purpose to the export the user almost certainly wants — vertical
    /// social formats for short/reel/highlight, landscape source quality
    /// otherwise. (The decision is purpose-first; platform is downstream.)
    static func suggestedPreset(forPurpose key: String) -> ExportPreset {
        switch key {
        case "short", "reel", "highlight", "clip", "fail":
            return .reels
        default:
            return .youtube1080p
        }
    }
}
