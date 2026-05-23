import SwiftUI

/// Horizontal strip showing the playhead and in/out markers across the source.
struct TimelineStripView: View {
    @ObservedObject var controller: PlayerController
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                Rectangle()
                    .fill(.tertiary)
                    .frame(height: 4)
                    .offset(y: 28)

                if let inMs = appState.playerInMs {
                    Rectangle().fill(.green.opacity(0.3))
                        .frame(width: width(forMs: (appState.playerOutMs ?? controller.currentMs) - inMs, total: controller.durationMs, geo: geo))
                        .offset(x: x(forMs: inMs, total: controller.durationMs, geo: geo), y: 24)
                        .frame(height: 12)
                }

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
