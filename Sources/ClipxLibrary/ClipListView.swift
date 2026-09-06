import SwiftUI

/// Sources and saved clips share the same table, with distinct stable identities
/// so a newly imported library remains usable before any ranges are marked.
struct ClipListView: View {
    let sources: [Source]
    let clips: [Clip]
    @EnvironmentObject private var appState: AppState
    @State private var selection: Set<Row.ID> = []
    @State private var pendingDelete: Set<Int64>?

    private struct Row: Identifiable {
        enum ID: Hashable { case source(Int64), clip(Int64) }
        let id: ID
        let name: String
        let durationMs: Int64
        var source: Source?
        var clip: Clip?
    }

    private var rows: [Row] {
        sources.compactMap { source in
            source.id.map { Row(id: .source($0), name: source.displayName,
                                durationMs: source.durationMs ?? 0, source: source) }
        } + clips.compactMap { clip in
            clip.id.map { Row(id: .clip($0), name: clip.name ?? "Untitled clip",
                              durationMs: clip.durationMs, clip: clip) }
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                Label(row.name, systemImage: row.clip == nil ? "film" : "scissors")
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            TableColumn("Type") { row in
                Text(row.clip == nil ? "Source" : "Saved clip")
                    .foregroundStyle(Theme.textSecondary)
            }
            .width(min: 65, ideal: 75, max: 90)
            TableColumn("Duration") { row in
                Text(PlayerController.formatMs(row.durationMs))
                    .monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            .width(min: 65, ideal: 85, max: 105)
            TableColumn("Rating") { row in
                if let clip = row.clip, let id = clip.id {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { value in
                            Button { setRating(id, clip.rating == value ? 0 : value) } label: {
                                Image(systemName: value <= clip.rating ? "star.fill" : "star")
                                    .font(.caption2)
                                    .foregroundStyle(value <= clip.rating ? Theme.star : Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rate \(row.name) \(value) stars")
                        }
                    }
                } else {
                    Text("—").foregroundStyle(Theme.textTertiary)
                }
            }
            .width(min: 82, ideal: 90, max: 110)
            TableColumn("Details") { row in
                Text(row.clip?.mood ?? row.source?.resolutionLabel ?? "")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            Button("Open") { open(ids.first) }
                .disabled(ids.isEmpty)
            let clipIDs = selectedClips(ids)
            if !clipIDs.isEmpty {
                Button("Show Inspector") {
                    appState.selectedClipIDs = clipIDs
                    appState.inspectorVisible = true
                }
                Divider()
                Menu("Export") {
                    Button("Reels (9:16 1080p)") { ExportActions.export(clipIDs: Array(clipIDs), preset: .reels) }
                    Button("YouTube 1080p") { ExportActions.export(clipIDs: Array(clipIDs), preset: .youtube1080p) }
                    Button("YouTube 4K") { ExportActions.export(clipIDs: Array(clipIDs), preset: .youtube4k) }
                }
                Divider()
                Button("Delete \(clipIDs.count) clip\(clipIDs.count == 1 ? "" : "s")", role: .destructive) {
                    pendingDelete = clipIDs
                }
            }
        } primaryAction: { ids in open(ids.first) }
        .onAppear { syncSelection() }
        .onChange(of: appState.selectedClipIDs) { _, _ in syncSelection() }
        .onChange(of: selection) { _, ids in
            appState.selectedClipIDs = selectedClips(ids)
            appState.selectedSourceID = ids.compactMap { id in
                if case .source(let value) = id { return value }
                return nil
            }.first
        }
        .background(Theme.bg)
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) clip\((pendingDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingDelete { MarkerActions.deleteClips(ids) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Source files stay in your library. You can undo this deletion from the confirmation message.") }
    }

    private func selectedClips(_ ids: Set<Row.ID>) -> Set<Int64> {
        Set(ids.compactMap { id in
            if case .clip(let value) = id { return value }
            return nil
        })
    }

    private func syncSelection() {
        let sourceSelection = selection.filter { if case .source = $0 { return true }; return false }
        let clipSelection = appState.selectedClipIDs.intersection(Set(clips.compactMap(\.id))).map(Row.ID.clip)
        let updated = sourceSelection.union(clipSelection)
        if selection != updated { selection = updated }
    }

    private func open(_ id: Row.ID?) {
        guard let id else { return }
        switch id {
        case .source(let value):
            appState.selectedSourceID = value
            appState.playerInMs = nil
            appState.playerOutMs = nil
            appState.playerSourceID = value
        case .clip(let value):
            if let clip = clips.first(where: { $0.id == value }) { appState.openClip(clip) }
        }
    }

    private func setRating(_ id: Int64, _ rating: Int) {
        do { try AppEnvironment.shared.markerStore?.updateRating(id, rating: rating) }
        catch { appState.showToast("Couldn't save rating: \(error.localizedDescription)", level: .error) }
    }
}
