import SwiftUI
import AppKit

/// A skimmable filmstrip timeline. Instead of a thin scrubber line, it draws
/// the source's sampled sprite strip across the full width — so a 20-minute
/// source is visually scannable and you can *see* where the action is — with
/// the in/out band, saved-clip pins, and playhead drawn over it.
///
/// Reuses the existing `ThumbnailEngine` sprite (a horizontal strip of ~10
/// frames), so there's no new media pipeline: the filmstrip is that strip
/// stretched to the timeline width.
struct FilmstripTimelineView: View {
    @ObservedObject var controller: PlayerController
    @EnvironmentObject private var appState: AppState
    let sourceHash: String?
    let sourceURL: URL?
    var savedClips: [Clip] = []
    var onSelectClip: ((Clip) -> Void)? = nil

    @State private var strip: NSImage?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let total = controller.durationMs
            let playX = x(forMs: controller.currentMs, total: total, geo: geo)
            ZStack(alignment: .topLeading) {
                // Filmstrip background (sampled frames) or a calm placeholder.
                Group {
                    if let strip {
                        Image(nsImage: strip)
                            .resizable()
                            .interpolation(.medium)
                    } else {
                        Rectangle().fill(Theme.bgRaised)
                    }
                }
                .frame(width: geo.size.width, height: h)
                .clipped()
                // Legibility wash so white/green overlays read over any frame.
                .overlay(Rectangle().fill(.black.opacity(0.20)))

                // Background scrub layer — drag/tap to seek. Sits behind the
                // saved-clip pins (which use highPriorityGesture) and playhead.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: geo.size.width, height: h)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            let frac = max(0, min(1, value.location.x / geo.size.width))
                            controller.seek(toMs: Int64(frac * Double(controller.durationMs)))
                        }
                    )
                    .accessibilityLabel("Filmstrip scrubber")

                // Already-saved clips as slim accent pins along the bottom edge.
                ForEach(savedClips, id: \.id) { clip in
                    let xStart = x(forMs: clip.inMs, total: total, geo: geo)
                    let w = width(forMs: clip.outMs - clip.inMs, total: total, geo: geo)
                    let visW = max(3, w)
                    let hitWidth = max(10, w)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.32))
                        .frame(width: visW, height: 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1)
                        )
                        .contentShape(Rectangle().inset(by: -((hitWidth - visW) / 2)))
                        .offset(x: xStart, y: h - 12)
                        .highPriorityGesture(TapGesture().onEnded { onSelectClip?(clip) })
                        .help(clip.name ?? "Clip \(clip.id ?? 0)")
                        .accessibilityLabel(Text(clip.name ?? "Saved clip"))
                }

                // Active in/out range — a full-height green frame on the strip.
                if let inMs = appState.playerInMs {
                    let endMs = max(inMs, appState.playerOutMs ?? controller.currentMs)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.success.opacity(0.22))
                        .frame(width: width(forMs: endMs - inMs, total: total, geo: geo), height: h)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Theme.success, lineWidth: 1.5)
                        )
                        .offset(x: x(forMs: inMs, total: total, geo: geo), y: 0)
                        .allowsHitTesting(false)
                }

                // Playhead — thin white line, full height, with a knob on top.
                ZStack(alignment: .top) {
                    Rectangle().fill(.white).frame(width: 2, height: h)
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(y: -3)
                }
                .offset(x: playX - 1, y: 0)
                .allowsHitTesting(false)
            }
        }
        .background(Theme.bgRaised)
        .task(id: sourceHash) { loadStrip() }
    }

    private func loadStrip() {
        strip = nil
        guard let hash = sourceHash, let url = sourceURL,
              let engine = AppEnvironment.shared.thumbnailEngine else { return }
        // Fast path: the sprite strip is already cached on disk.
        let cached = engine.spritePath(for: hash)
        if let img = NSImage(contentsOf: cached) {
            strip = img
            return
        }
        // Generate on demand. ThumbnailEngine dedupes concurrent requests and
        // fires completion on main.
        let stub = Source(
            id: nil, path: url.path, bookmark: nil, hash: hash, mtime: 0,
            durationMs: nil, width: nil, height: nil, fps: nil, codec: nil,
            audioChannels: nil, colorSpace: nil, createdAt: nil,
            importedAt: 0, thumbPath: nil, online: true, notes: nil
        )
        engine.generateSprite(source: stub) { resultURL in
            guard let resultURL, let img = NSImage(contentsOf: resultURL) else { return }
            self.strip = img
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
