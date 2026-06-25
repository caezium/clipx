import SwiftUI
import GRDB

/// The harvest surface. Every marked clip, grouped by the *purpose* you gave it
/// (Coach / Reel / Publish…), each group with a goal-first export. This is where
/// find→mark→tag pays off: the decision you already made drives the export, so
/// you never think in resolutions.
struct LightTableView: View {
    @EnvironmentObject private var appState: AppState
    @State private var clipsByPurpose: [String: [Clip]] = [:]

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if clipsByPurpose.isEmpty {
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
        .onChange(of: appState.selectedProjectID) { _, _ in load() }
        .onChange(of: appState.selectedCollectionID) { _, _ in load() }
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
            HStack(spacing: 8) {
                Image(systemName: Purposes.symbol(forKey: key))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                Text(Purposes.title(forKey: key))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(clips.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    let ids = clips.compactMap(\.id)
                    Task { await StintBridge.sendToReview(clipIDs: ids, projectName: "\(Purposes.title(forKey: key)) — Clipx") }
                } label: {
                    Label("Send to review", systemImage: "paperplane")
                }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .fixedSize()
                .help("Render these clips into a Stint project and copy a share link for frame-pinned comments")
                Button {
                    // Export this group directly without hijacking the user's
                    // current selection (which exportSelected would read).
                    ExportActions.export(clipIDs: clips.compactMap(\.id), preset: preset)
                } label: {
                    Label("Export \(clips.count) · \(preset.displayName)", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(kind: .accent, compact: true))
                .fixedSize()
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("Nothing tagged yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Mark a clip and tap a purpose (Coach, Reel, Publish…) — it lands here, ready to export.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 360)
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
        if let id = clip.id { appState.selectedClipIDs = [id] }
        appState.playerSourceID = clip.sourceID
        appState.playerInMs = clip.inMs
        appState.playerOutMs = clip.outMs
    }

    private func load() {
        // Read the sidebar scope on the main actor before detaching.
        let projectID = appState.selectedProjectID
        let collectionID = appState.selectedCollectionID
        Task.detached(priority: .userInitiated) {
            guard let db = AppEnvironment.shared.database else { return }
            var clauses = ["purpose IS NOT NULL", "purpose != ''"]
            var args: [DatabaseValueConvertible] = []
            if let projectID {
                clauses.append("id IN (SELECT clip_id FROM clip_projects WHERE project_id = ?)")
                args.append(projectID)
            }
            if let collectionID {
                clauses.append("id IN (SELECT clip_id FROM clip_collections WHERE collection_id = ?)")
                args.append(collectionID)
            }
            let sql = "SELECT * FROM clips WHERE \(clauses.joined(separator: " AND ")) "
                + "ORDER BY rating DESC, created_at DESC"
            let clips: [Clip] = (try? db.read { dbc in
                try Clip.fetchAll(dbc, sql: sql, arguments: StatementArguments(args))
            }) ?? []
            var buckets: [String: [Clip]] = [:]
            for clip in clips {
                for key in clip.purposeList { buckets[key, default: []].append(clip) }
            }
            let final = buckets
            await MainActor.run { self.clipsByPurpose = final }
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
