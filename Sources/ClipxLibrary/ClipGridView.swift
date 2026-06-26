import SwiftUI
import AppKit

struct ClipGridView: View {
    let sources: [Source]
    let clips: [Clip]
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !clips.isEmpty {
                    sectionHeader(title: "Clips", count: clips.count)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(clips) { clip in
                            ClipCardView(
                                clip: clip,
                                isSelected: clip.id.map { appState.selectedClipIDs.contains($0) } ?? false,
                                onSelect: { selectSingle(clip.id ?? 0) },
                                onToggle: { toggleAdditive(clip.id ?? 0) },
                                onOpenInPlayer: { openInPlayer(clip: clip) }
                            )
                            // Drag-out exports at source quality (1080p, no
                            // aspect crop) so dropping into Finder gives a
                            // useful file. Was hardcoded to Reels which
                            // crops 9:16 destructively.
                            .draggable(ClipTransferable(clipID: clip.id ?? 0, preset: .youtube1080p))
                            .contextMenu { clipContextMenu(clip: clip) }
                        }
                    }
                }

                // Hide the all-sources grid when the user is filtering by a
                // project — they want to see the project's clips, not the
                // unrelated full source library.
                if !sources.isEmpty && appState.selectedProjectID == nil {
                    sectionHeader(title: "Sources", count: sources.count)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sources) { source in
                            SourceCardView(source: source) {
                                appState.selectedClipIDs = []
                                appState.playerSourceID = source.id
                                appState.playerInMs = nil
                                appState.playerOutMs = nil
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Theme.surface, in: Capsule())
        }
    }

    /// Plain click → single selection. (#29)
    private func selectSingle(_ clipID: Int64) {
        appState.selectedClipIDs = [clipID]
        if !appState.inspectorVisible { appState.inspectorVisible = true }
    }

    /// ⌘-click → additive toggle, building a multi-selection without clearing
    /// the rest (so batch export becomes reachable). (#29)
    private func toggleAdditive(_ clipID: Int64) {
        if appState.selectedClipIDs.contains(clipID) {
            appState.selectedClipIDs.remove(clipID)
        } else {
            appState.selectedClipIDs.insert(clipID)
            if !appState.inspectorVisible { appState.inspectorVisible = true }
        }
    }

    private func openInPlayer(clip: Clip) {
        if let id = clip.id { appState.selectedClipIDs = [id] }
        appState.playerSourceID = clip.sourceID
        appState.playerInMs = clip.inMs
        appState.playerOutMs = clip.outMs
    }

    @ViewBuilder
    private func clipContextMenu(clip: Clip) -> some View {
        Button("Open in Player") { openInPlayer(clip: clip) }
        Button("Show Inspector") {
            if let id = clip.id { appState.selectedClipIDs = [id] }
            appState.inspectorVisible = true
        }
        Divider()
        Menu("Export") {
            Section("Social") {
                Button("Reels (9:16 1080p)") { quickExport(clip: clip, preset: .reels) }
                Button("TikTok") { quickExport(clip: clip, preset: .tiktok) }
                Button("YouTube Shorts") { quickExport(clip: clip, preset: .youtubeShorts) }
                Button("Instagram Feed (4:5)") { quickExport(clip: clip, preset: .instagramFeed) }
            }
            Section("YouTube") {
                Button("YouTube 1080p") { quickExport(clip: clip, preset: .youtube1080p) }
                Button("YouTube 4K") { quickExport(clip: clip, preset: .youtube4k) }
            }
            Section("Bridges") {
                Button("FCPXML…") {
                    if let id = clip.id { appState.selectedClipIDs = [id] }
                    ExportActions.exportFCPXML()
                }
                Button("Obsidian Sidecar…") {
                    if let id = clip.id { appState.selectedClipIDs = [id] }
                    ExportActions.exportObsidian()
                }
            }
        }
        Divider()
        Button("Delete clip", role: .destructive) { deleteWithUndo(clip: clip) }
    }

    /// Delete a clip but capture its full state first and offer an Undo on the
    /// toast — marks, tags, rating, notes, and project assignments are all
    /// restored if the user undoes. (#30)
    private func deleteWithUndo(clip: Clip) {
        guard let id = clip.id,
              let markerStore = AppEnvironment.shared.markerStore,
              let database = AppEnvironment.shared.database else { return }
        let tagStore = AppEnvironment.shared.tagStore
        let snapshot = clip
        let tags = (try? tagStore?.tags(forClip: id).map(\.name)) ?? []
        let projectIDs: [Int64] = (try? database.read { db in
            try Int64.fetchAll(db, sql: "SELECT project_id FROM clip_projects WHERE clip_id = ?", arguments: [id])
        }) ?? []
        do {
            try markerStore.deleteClip(id)
            appState.selectedClipIDs.remove(id)
            AppState.shared.showToast(
                "Deleted “\(snapshot.name ?? "clip")”",
                level: .info,
                actionLabel: "Undo"
            ) {
                restore(snapshot: snapshot, tags: tags, projectIDs: projectIDs)
            }
        } catch {
            AppState.shared.showToast("Delete failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func restore(snapshot: Clip, tags: [String], projectIDs: [Int64]) {
        guard let markerStore = AppEnvironment.shared.markerStore,
              let database = AppEnvironment.shared.database,
              let clip = try? markerStore.saveRange(
                sourceID: snapshot.sourceID, inMs: snapshot.inMs, outMs: snapshot.outMs,
                name: snapshot.name
              ),
              let newID = clip.id else { return }
        try? database.write { db in
            try db.execute(
                sql: "UPDATE clips SET rating=?, color_label=?, mood=?, shot_type=?, camera_move=?, setting=?, notes=? WHERE id=?",
                arguments: [snapshot.rating, snapshot.colorLabel, snapshot.mood, snapshot.shotType,
                            snapshot.cameraMove, snapshot.setting, snapshot.notes, newID]
            )
            for pid in projectIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO clip_projects(clip_id, project_id) VALUES(?,?)",
                               arguments: [newID, pid])
            }
        }
        for t in tags { try? AppEnvironment.shared.tagStore?.addTag(t, toClip: newID) }
        AppState.shared.libraryRevision &+= 1
    }

    private func quickExport(clip: Clip, preset: ExportPreset) {
        if let id = clip.id { appState.selectedClipIDs = [id] }
        ExportActions.exportSelected(preset)
    }
}

/// Single-tap toggles selection (no double-tap delay). The "open in player"
/// action is exposed via a hover-revealed play button on the thumbnail so it
/// remains one click away, plus the right-click menu.
struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let onSelect: () -> Void
    var onToggle: () -> Void = {}
    let onOpenInPlayer: () -> Void

    @State private var thumbImage: NSImage?
    @State private var sourceName: String = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(
                    Group {
                        if let img = thumbImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                )
                .overlay(alignment: .center) {
                    // Hover-revealed play button. Provides a discoverable
                    // single-click affordance for "open in player" without
                    // forcing a double-click on the card body.
                    if hovering {
                        Button(action: onOpenInPlayer) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .help("Open in player")
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors").font(.caption2)
                        Text("\(formatDuration(clip.inMs)) → \(formatDuration(clip.outMs))")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.success.opacity(0.9), in: Capsule())
                    .padding(.bottom, 6)
                }
                .clipxMediaEdge()
                .overlay(alignment: .topTrailing) {
                    Text(formatDuration(clip.durationMs))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let label = clip.colorLabel, label > 0 {
                        Circle().fill(colorForLabel(label)).frame(width: 8, height: 8)
                            .accessibilityLabel("Color label: \(colorName(label))")   // not hue-only (#40)
                    }
                    Text(clip.name ?? defaultName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if clip.rating > 0 {
                        Text(String(repeating: "★", count: clip.rating))
                            .font(.caption2)
                            .foregroundStyle(Theme.star)
                    }
                }
                if !sourceName.isEmpty && clip.name != nil {
                    Text(sourceName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
        .clipxCard(radius: Theme.r2, selected: isSelected)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        // Consistent gesture model: double-click opens, ⌘-click extends the
        // selection, plain click selects. (#36, #29)
        .onTapGesture(count: 2) { onOpenInPlayer() }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { onToggle() } else { onSelect() }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(clip.name ?? defaultName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear { loadThumb() }
    }

    private var defaultName: String {
        sourceName.isEmpty ? "Untitled clip" : sourceName
    }

    /// Card pixel size to decode thumbnails at — cards render ~220–280pt wide,
    /// so ~360px covers normal and most Retina densities without holding the
    /// full 480px cache bitmap per card. `fileprivate` so `SourceCardView`
    /// shares the same target size.
    fileprivate static let thumbMaxPixel = 360

    private func loadThumb() {
        guard let thumbnailEngine = AppEnvironment.shared.thumbnailEngine else { return }
        // Resolve the source identity from a memoized lookup (no per-card SQLite
        // query on scroll), then hand off to the memory-cached, downsampled
        // image loader. Both steps are near-instant once warm.
        Task.detached(priority: .utility) { [clip] in
            guard let meta = thumbnailEngine.sourceThumbMeta(for: clip.sourceID) else { return }
            await MainActor.run { self.sourceName = meta.displayName }
            thumbnailEngine.displayThumbnail(
                forHash: meta.hash, sourcePath: meta.path, maxPixel: Self.thumbMaxPixel
            ) { img in
                self.thumbImage = img   // completion fires on main
            }
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let m = totalSec / 60, s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private func colorForLabel(_ label: Int) -> Color {
        switch label {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .blue
        case 6: return .purple
        case 7: return .gray
        default: return .clear
        }
    }

    private func colorName(_ label: Int) -> String {
        switch label {
        case 1: return "red"
        case 2: return "orange"
        case 3: return "yellow"
        case 4: return "green"
        case 5: return "blue"
        case 6: return "purple"
        case 7: return "gray"
        default: return "labeled"
        }
    }
}

struct SourceCardView: View {
    let source: Source
    var onOpen: (() -> Void)? = nil
    @State private var thumbImage: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Color.clear is the size anchor — it fills width and stamps the
            // 16:9 height. The image overlays it and scales-to-fill, so
            // unusual native aspects (square, vertical) don't leak through.
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(
                    Group {
                        if let img = thumbImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                )
                .clipxMediaEdge()
                .overlay(alignment: .center) {
                    if hovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white)
                            .shadow(radius: 5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !source.online {
                        Text("Offline").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let durationMs = source.durationMs, durationMs > 0 {
                        Text(SourceCardView.formatDuration(durationMs))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(source.resolutionLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            HStack(spacing: 4) {
                Text(source.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let fps = source.fps {
                    Text("\(Int(fps))p")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
        .clipxCard(radius: Theme.r2)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(source.displayName))
        .accessibilityAddTraits(.isButton)
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        guard let thumbnailEngine = AppEnvironment.shared.thumbnailEngine else { return }
        // Warm hit: paint synchronously so a card scrolling back into view never
        // flickers a placeholder while a task hops to fetch what's already cached.
        if let warm = thumbnailEngine.cachedImage(forHash: source.hash) {
            thumbImage = warm
            return
        }
        // The source row is already in hand, so go straight to the memory-cached,
        // downsampled loader — no disk read or full-size decode on scroll recycle.
        thumbnailEngine.displayThumbnail(
            forHash: source.hash, sourcePath: source.path, maxPixel: ClipCardView.thumbMaxPixel
        ) { img in
            self.thumbImage = img   // completion fires on main
        }
    }

    static func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
