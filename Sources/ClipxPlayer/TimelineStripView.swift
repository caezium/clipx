import SwiftUI

/// Horizontal strip showing the playhead, in/out markers, and any clips that
/// have already been saved from the current source.
///
/// Gesture priority: the parent drag scrubs the playhead, but the saved-clip
/// bars use `highPriorityGesture` so clicking a saved clip loads its range
/// instead of dragging the playhead onto it.
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
            let total = controller.durationMs
            let playX = x(forMs: controller.currentMs, total: total, geo: geo)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.bgRaised)

                // Base track — thin, centered.
                Capsule()
                    .fill(Theme.surfaceHover)
                    .frame(height: 4)
                    .accessibilityHidden(true)

                // Played portion — the blue→white scrubber gradient.
                Capsule()
                    .fill(Theme.scrubber)
                    .frame(width: max(0, playX), height: 4)
                    .accessibilityHidden(true)

                // Background scrub layer — drag/tap to seek. Sits behind the
                // saved-clip bars and the playhead; bars use highPriorityGesture
                // so they win the hit test for their own pixels.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let frac = max(0, min(1, value.location.x / geo.size.width))
                                let target = Int64(frac * Double(controller.durationMs))
                                controller.seek(toMs: target)
                            }
                    )
                    .accessibilityLabel("Timeline scrubber")

                // Previously saved clips as slim accent pins.
                ForEach(savedClips, id: \.id) { clip in
                    let xStart = x(forMs: clip.inMs, total: total, geo: geo)
                    let w = width(forMs: clip.outMs - clip.inMs, total: total, geo: geo)
                    // Min hit width of 8pt so densely packed clips remain tappable.
                    let visW = max(3, w)
                    let hitWidth = max(8, w)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.30))
                        .frame(width: visW, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1)
                        )
                        .contentShape(Rectangle().inset(by: -((hitWidth - visW) / 2)))
                        .offset(x: xStart)
                        // Win the hit test against the parent scrub gesture.
                        .highPriorityGesture(
                            TapGesture().onEnded { onSelectClip?(clip) }
                        )
                        .help(clip.name ?? "Clip \(clip.id ?? 0)")
                        .accessibilityLabel(Text(clip.name ?? "Saved clip"))
                }

                // Active in/out range overlay — green, above the saved pins.
                if let inMs = appState.playerInMs {
                    let endMs = max(inMs, appState.playerOutMs ?? controller.currentMs)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.success.opacity(0.40))
                        .frame(width: width(forMs: endMs - inMs, total: total, geo: geo), height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Theme.success, lineWidth: 1)
                        )
                        .offset(x: x(forMs: inMs, total: total, geo: geo))
                        .allowsHitTesting(false)
                }

                // Playhead — thin white line with a knob at the track.
                ZStack {
                    Capsule().fill(.white)
                        .frame(width: 2, height: 44)
                    Circle().fill(.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .offset(x: playX - 4.5)
                .allowsHitTesting(false)
            }
        }
    }

    private func x(forMs ms: Int64, total: Int64, geo: GeometryProxy) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(max(0, ms)) / Double(total)) * geo.size.width
    }

    private func width(forMs ms: Int64, total: Int64, geo: GeometryProxy) -> CGFloat {
        guard total > 0, ms > 0 else { return 0 }
        return max(0, CGFloat(Double(ms) / Double(total)) * geo.size.width)
    }
}
