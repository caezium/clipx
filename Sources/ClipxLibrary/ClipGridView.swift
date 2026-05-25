import SwiftUI

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
                                onSelect: { toggleSelection(clipID: clip.id ?? 0) },
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
                            SourceCardView(source: source)
                                .onTapGesture {
                                    appState.selectedClipIDs = []
                                    appState.playerSourceID = source.id
                                    appState.playerInMs = nil
                                    appState.playerOutMs = nil
                                }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private func toggleSelection(clipID: Int64) {
        if appState.selectedClipIDs.contains(clipID) {
            appState.selectedClipIDs.remove(clipID)
        } else {
            appState.selectedClipIDs = [clipID]
            // Surface the Inspector automatically the first time the user
            // selects a clip — otherwise the tag / project / notes panes
            // aren't discoverable.
            if !appState.inspectorVisible {
                appState.inspectorVisible = true
            }
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
        Button("Delete clip", role: .destructive) {
            guard let id = clip.id, let markerStore = AppEnvironment.shared.markerStore else { return }
            do {
                try markerStore.deleteClip(id)
                appState.selectedClipIDs.remove(id)
                AppState.shared.showToast("Clip deleted", level: .info)
            } catch {
                AppState.shared.showToast("Delete failed: \(error.localizedDescription)", level: .error)
            }
        }
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
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.green.opacity(0.85), in: Capsule())
                    .padding(.bottom, 6)
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Text(formatDuration(clip.durationMs))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let label = clip.colorLabel, label > 0 {
                        Circle().fill(colorForLabel(label)).frame(width: 8, height: 8)
                    }
                    Text(clip.name ?? defaultName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if clip.rating > 0 {
                        Text(String(repeating: "★", count: clip.rating))
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if !sourceName.isEmpty && clip.name != nil {
                    Text(sourceName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.separator)
                .opacity(isSelected ? 0 : 1)
        )
        .contentShape(Rectangle())
        // Single-tap selects. The hover play button handles "open in player".
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(clip.name ?? defaultName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear { loadThumb() }
    }

    private var defaultName: String {
        sourceName.isEmpty ? "Untitled clip" : sourceName
    }

    private func loadThumb() {
        Task.detached(priority: .background) { [clip] in
            guard let database = AppEnvironment.shared.database,
                  let thumbnailEngine = AppEnvironment.shared.thumbnailEngine else { return }
            guard let source: Source = try? database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { return }
            let url = thumbnailEngine.thumbPath(for: source.hash)
            let img: NSImage? = (FileManager.default.fileExists(atPath: url.path)
                ? NSImage(contentsOf: url) : nil)
            let name = source.displayName
            await MainActor.run {
                if let img { self.thumbImage = img }
                self.sourceName = name
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
}

struct SourceCardView: View {
    let source: Source
    @State private var thumbImage: NSImage?

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
                .clipped()
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
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let fps = source.fps {
                    Text("\(Int(fps))p")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(source.displayName))
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        Task.detached(priority: .background) { [source] in
            guard let thumbnailEngine = AppEnvironment.shared.thumbnailEngine else { return }
            let url = thumbnailEngine.thumbPath(for: source.hash)
            if FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                await MainActor.run { self.thumbImage = image }
            }
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
