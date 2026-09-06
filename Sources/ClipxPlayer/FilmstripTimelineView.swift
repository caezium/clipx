import SwiftUI
import AppKit

/// Shared ms→pixel mapping for the timeline so the static pins and the moving
/// playhead/leaf can't drift apart. One formula, one place.
enum TimelineMath {
    static func x(forMs ms: Int64, total: Int64, width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(min(total, max(0, ms))) / Double(total)) * width
    }

    static func width(forMs ms: Int64, total: Int64, fullWidth: CGFloat) -> CGFloat {
        guard total > 0, ms > 0 else { return 0 }
        return max(0, CGFloat(Double(ms) / Double(total)) * fullWidth)
    }
}

/// A skimmable filmstrip timeline. Instead of a thin scrubber line, it draws
/// the source's sampled sprite strip across the full width — so a 20-minute
/// source is visually scannable and you can *see* where the action is — with
/// the in/out band, saved-clip pins, and playhead drawn over it.
///
/// Reuses the existing `ThumbnailEngine` sprite (a horizontal strip of ~10
/// frames), so there's no new media pipeline: the filmstrip is that strip
/// stretched to the timeline width.
struct FilmstripTimelineView: View {
    /// Plain reference, *not* `@ObservedObject` — observing the controller would
    /// re-run this whole body (incl. the saved-clip `ForEach` geometry) on every
    /// playhead tick. We only need `controller` for seek actions; the duration is
    /// passed in as `totalMs` and the moving playhead lives in a leaf that
    /// observes the clock. (See PlaybackClock.)
    let controller: PlayerController
    /// Source duration, passed from the player so this view reacts to it loading
    /// without subscribing to the per-frame clock.
    let totalMs: Int64
    @EnvironmentObject private var appState: AppState
    let sourceHash: String?
    let sourceURL: URL?
    var savedClips: [Clip] = []
    var onSelectClip: ((Clip) -> Void)? = nil

    @State private var strip: NSImage?
    @State private var stripGeneration = UUID()

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let total = totalMs
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
                            guard geo.size.width > 0 else { return }
                            let frac = max(0, min(1, value.location.x / geo.size.width))
                            controller.seek(toMs: Int64(frac * Double(controller.durationMs)))
                        }
                    )
                    .accessibilityLabel("Filmstrip scrubber")
                    .accessibilityValue(PlayerController.formatMs(controller.currentMs))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: controller.stepForward()
                        case .decrement: controller.stepBackward()
                        @unknown default: break
                        }
                    }

                // Already-saved clips as slim accent pins along the bottom edge.
                ForEach(savedClips, id: \.id) { clip in
                    let xStart = TimelineMath.x(forMs: clip.inMs, total: total, width: geo.size.width)
                    let w = TimelineMath.width(forMs: clip.durationMs, total: total, fullWidth: geo.size.width)
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
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onSelectClip?(clip) }
                }

                // Moving parts (in/out band + playhead) isolated in a leaf that
                // observes the clock — so only this thin overlay redraws per
                // frame, not the filmstrip or the saved-clip pins above.
                FilmstripPlayhead(
                    clock: controller.clock,
                    totalMs: total,
                    size: geo.size,
                    inMs: appState.playerInMs,
                    outMs: appState.playerOutMs
                )
            }
        }
        .background(Theme.bgRaised)
        .task(id: sourceHash) { loadStrip() }
        .onDisappear { stripGeneration = UUID() }
    }

    // (ms→pixel mapping lives in TimelineMath, shared with the playhead leaf.)

    private func loadStrip() {
        let generation = UUID()
        stripGeneration = generation
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
            Task { @MainActor in
                guard stripGeneration == generation else { return }
                self.strip = img
            }
        }
    }
}

/// The only per-frame-updating part of the filmstrip: the playhead, plus the
/// active in/out band (whose right edge tracks the playhead while marking).
/// Observes just the `PlaybackClock`, so the filmstrip image and the saved-clip
/// pins around it render once and stay static during playback.
private struct FilmstripPlayhead: View {
    @ObservedObject var clock: PlaybackClock
    let totalMs: Int64
    let size: CGSize
    let inMs: Int64?
    let outMs: Int64?

    var body: some View {
        let cur = clock.currentMs
        let h = size.height
        ZStack(alignment: .topLeading) {
            // Active in/out range — a full-height green frame on the strip.
            if let inMs {
                let endMs = max(inMs, outMs ?? cur)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.success.opacity(0.22))
                    .frame(width: TimelineMath.width(forMs: endMs - inMs, total: totalMs, fullWidth: size.width), height: h)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.success, lineWidth: 1.5)
                    )
                    .offset(x: TimelineMath.x(forMs: inMs, total: totalMs, width: size.width), y: 0)
                    .allowsHitTesting(false)
            }

            // Playhead — thin white line, full height, with a knob on top.
            ZStack(alignment: .top) {
                Rectangle().fill(.white).frame(width: 2, height: h)
                Circle().fill(.white).frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(y: -3)
            }
            .offset(x: TimelineMath.x(forMs: cur, total: totalMs, width: size.width) - 1, y: 0)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: h, alignment: .topLeading)
    }
}
