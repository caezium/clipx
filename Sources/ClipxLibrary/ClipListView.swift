import SwiftUI

/// List view at parity with the grid: a real Table whose selection is the same
/// `selectedClipIDs` the grid and export use, with open-in-player, context
/// actions, and inline rating. (#37)
struct ClipListView: View {
    let sources: [Source]
    let clips: [Clip]
    @EnvironmentObject private var appState: AppState
    @State private var pendingDelete: Set<Int64>?

    /// Table selection needs a non-optional row id; Clip.id is Int64?.
    private struct Row: Identifiable { let id: Int64; let clip: Clip }
    private var rows: [Row] { clips.compactMap { c in c.id.map { Row(id: $0, clip: c) } } }

    var body: some View {
        Table(rows, selection: $appState.selectedClipIDs) {
            TableColumn("Name") { row in
                Text(row.clip.name ?? "Untitled").foregroundStyle(Theme.textPrimary)
            }
            TableColumn("Duration") { row in
                Text(format(row.clip.durationMs)).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            TableColumn("Rating") { row in
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= row.clip.rating ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(i <= row.clip.rating ? Theme.star : Theme.textTertiary)
                            .onTapGesture { setRating(row.id, i) }
                    }
                }
            }
            TableColumn("Mood") { row in Text(row.clip.mood ?? "").foregroundStyle(Theme.textSecondary) }
            TableColumn("Shot") { row in Text(row.clip.shotType ?? "").foregroundStyle(Theme.textSecondary) }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Open in Player") { open(ids.first) }
            Button("Show Inspector") {
                if let id = ids.first { appState.selectedClipIDs = [id]; appState.inspectorVisible = true }
            }
            Divider()
            Menu("Export") {
                Button("Reels (9:16 1080p)") { exportSelected(ids, .reels) }
                Button("YouTube 1080p") { exportSelected(ids, .youtube1080p) }
                Button("YouTube 4K") { exportSelected(ids, .youtube4k) }
            }
            Divider()
            Button("Delete \(ids.count) clip\(ids.count == 1 ? "" : "s")", role: .destructive) {
                pendingDelete = ids
            }
        } primaryAction: { ids in
            open(ids.first)   // double-click opens
        }
        .background(Theme.bg)
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) clip\((pendingDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingDelete { deleteClips(ids) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes their marks, tags, ratings, and notes.")
        }
    }

    private func open(_ id: Int64?) {
        guard let id, let clip = clips.first(where: { $0.id == id }) else { return }
        appState.selectedClipIDs = [id]
        appState.playerSourceID = clip.sourceID
        appState.playerInMs = clip.inMs
        appState.playerOutMs = clip.outMs
    }

    private func setRating(_ id: Int64, _ rating: Int) {
        try? AppEnvironment.shared.markerStore?.updateRating(id, rating: rating)
    }

    private func exportSelected(_ ids: Set<Int64>, _ preset: ExportPreset) {
        appState.selectedClipIDs = ids
        ExportActions.exportSelected(preset)
    }

    private func deleteClips(_ ids: Set<Int64>) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        for id in ids { try? markerStore.deleteClip(id) }
        appState.selectedClipIDs.subtract(ids)
        AppState.shared.showToast("Deleted \(ids.count) clip\(ids.count == 1 ? "" : "s")", level: .info)
    }

    private func format(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let m = totalSec / 60, s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }
}
