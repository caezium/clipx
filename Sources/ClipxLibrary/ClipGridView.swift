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
                            ClipCardView(clip: clip)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(appState.selectedClipIDs.contains(clip.id ?? -1) ? Color.accentColor : .clear, lineWidth: 2)
                                )
                                .onTapGesture(count: 2) {
                                    let id = clip.id ?? -1
                                    appState.selectedClipIDs = [id]
                                    appState.playerSourceID = clip.sourceID
                                    appState.playerInMs = clip.inMs
                                    appState.playerOutMs = clip.outMs
                                }
                                .onTapGesture {
                                    toggleSelection(clipID: clip.id ?? 0)
                                }
                                .draggable(ClipTransferable(clipID: clip.id ?? 0, preset: .reels))
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
                                .onTapGesture(count: 2) {
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

    @ViewBuilder
    private func clipContextMenu(clip: Clip) -> some View {
        Button("Open in Player") {
            if let id = clip.id { appState.selectedClipIDs = [id] }
            appState.playerSourceID = clip.sourceID
            appState.playerInMs = clip.inMs
            appState.playerOutMs = clip.outMs
        }
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
            guard let id = clip.id else { return }
            do {
                try AppEnvironment.shared.markerStore.deleteClip(id)
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

struct ClipCardView: View {
    let clip: Clip
    @State private var thumbImage: NSImage?
    @State private var sourceName: String = ""

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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .onAppear { loadThumb() }
    }

    private var defaultName: String {
        sourceName.isEmpty ? "Untitled clip" : sourceName
    }

    private func loadThumb() {
        Task.detached(priority: .background) { [clip] in
            let env = AppEnvironment.shared
            guard let database = env.database, let thumbnailEngine = env.thumbnailEngine else { return }
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
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        Task.detached(priority: .background) { [source] in
            let env = AppEnvironment.shared
            guard let thumbnailEngine = env.thumbnailEngine else { return }
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
