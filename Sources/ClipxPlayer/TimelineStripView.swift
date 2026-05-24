import SwiftUI

/// Horizontal strip showing the playhead, in/out markers, and any clips that
/// have already been saved from the current source.
struct TimelineStripView: View {
    @ObservedObject var controller: PlayerController
    @EnvironmentObject private var appState: AppState
    /// Clips already saved from the current source — rendered as muted bars
    /// so the user sees what they've already captured.
    var savedClips: [Clip] = []
    /// Callback when the user clicks a saved-clip bar — loads its range.
    var onSelectClip: ((Clip) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                // Base track
                Rectangle()
                    .fill(.tertiary)
                    .frame(height: 4)
                    .offset(y: 28)

                // Previously saved clips as faint blue bars, full timeline height
                ForEach(savedClips, id: \.id) { clip in
                    let xStart = x(forMs: clip.inMs, total: controller.durationMs, geo: geo)
                    let w = width(forMs: clip.outMs - clip.inMs, total: controller.durationMs, geo: geo)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: max(2, w), height: 38)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.accentColor).frame(width: 1)
                        }
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Color.accentColor).frame(width: 1)
                        }
                        .offset(x: xStart, y: 11)
                        .onTapGesture { onSelectClip?(clip) }
                        .help(clip.name ?? "Clip \(clip.id ?? 0)")
                }

                // Active in/out range overlay — bright green, sits above saved
                // clip bars
                if let inMs = appState.playerInMs {
                    Rectangle().fill(.green.opacity(0.45))
                        .frame(width: width(forMs: (appState.playerOutMs ?? controller.currentMs) - inMs, total: controller.durationMs, geo: geo))
                        .offset(x: x(forMs: inMs, total: controller.durationMs, geo: geo), y: 22)
                        .frame(height: 16)
                }

                // Playhead
                Rectangle().fill(.red)
                    .frame(width: 2, height: 50)
                    .offset(x: x(forMs: controller.currentMs, total: controller.durationMs, geo: geo), y: 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let frac = max(0, min(1, value.location.x / geo.size.width))
                        let target = Int64(frac * Double(controller.durationMs))
                        controller.seek(toMs: target)
                    }
            )
        }
    }

    private func x(forMs ms: Int64, total: Int64, geo: GeometryProxy) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(ms) / Double(total)) * geo.size.width
    }

    private func width(forMs ms: Int64, total: Int64, geo: GeometryProxy) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(0, CGFloat(Double(ms) / Double(total)) * geo.size.width)
    }
}
