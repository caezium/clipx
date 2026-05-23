import SwiftUI

struct ClipGridView: View {
    let sources: [Source]
    let clips: [Clip]
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                if !clips.isEmpty {
                    ForEach(clips) { clip in
                        ClipCardView(clip: clip)
                            .onTapGesture(count: 2) {
                                // Open in player and seek to in-point
                                appState.playerSourceID = clip.sourceID
                                appState.playerInMs = clip.inMs
                                appState.playerOutMs = clip.outMs
                            }
                            .onTapGesture {
                                toggleSelection(clipID: clip.id ?? 0)
                            }
                            .draggable(ClipTransferable(clipID: clip.id ?? 0, preset: .reels))
                    }
                } else {
                    ForEach(sources) { source in
                        SourceCardView(source: source)
                            .onTapGesture(count: 2) {
                                appState.playerSourceID = source.id
                            }
                    }
                }
            }
            .padding(12)
        }
    }

    private func toggleSelection(clipID: Int64) {
        if appState.selectedClipIDs.contains(clipID) {
            appState.selectedClipIDs.remove(clipID)
        } else {
            appState.selectedClipIDs.insert(clipID)
        }
    }
}

struct ClipCardView: View {
    let clip: Clip
    @State private var thumbImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let img = thumbImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(16/9, contentMode: .fit)
                }
            }
            .aspectRatio(16/9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(clip.durationMs))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }

            HStack(spacing: 4) {
                if let label = clip.colorLabel, label > 0 {
                    Circle().fill(colorForLabel(label)).frame(width: 8, height: 8)
                }
                Text(clip.name ?? "Untitled clip")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if clip.rating > 0 {
                    Text(String(repeating: "★", count: clip.rating))
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        Task.detached(priority: .background) { [clip] in
            let env = AppEnvironment.shared
            guard let database = env.database, let thumbnailEngine = env.thumbnailEngine else { return }
            guard let source: Source = try? database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { return }
            let url = thumbnailEngine.thumbPath(for: source.hash)
            if FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                await MainActor.run { self.thumbImage = image }
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
            ZStack {
                if let img = thumbImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(16/9, contentMode: .fill)
            .frame(maxWidth: .infinity)
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
            .overlay(alignment: .bottomTrailing) {
                Text(source.resolutionLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }

            Text(source.displayName)
                .font(.caption)
                .lineLimit(1)
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
}
