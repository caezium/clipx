import SwiftUI
import AVKit
import AVFoundation

/// Built-in player with frame-accurate scrubbing and I/O marking hotkeys.
struct PlayerView: View {
    let sourceID: Int64
    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = PlayerController()
    @State private var source: Source?
    @State private var savedClips: [Clip] = []
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The PlayerSurface (AVPlayerLayer) does its own aspect-correct
            // letterboxing via videoGravity = .resizeAspect, so we don't ask
            // SwiftUI to enforce a ratio — that was forcing the detail column
            // to demand a huge minimum width and crushing the sidebar.
            ZStack {
                Color.black
                if let player = controller.player {
                    PlayerSurface(player: player)
                        .contentShape(Rectangle())
                        .onTapGesture { keyboardFocused = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(-1)

            TimelineStripView(
                controller: controller,
                savedClips: savedClips,
                onSelectClip: { clip in
                    appState.playerInMs = clip.inMs
                    appState.playerOutMs = clip.outMs
                    controller.seek(toMs: clip.inMs)
                }
            )
            .frame(height: 60)
            controlBar
            if !savedClips.isEmpty {
                savedClipsStrip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear {
            load()
            reloadSavedClips()
            // Defer until the view is in the hierarchy or focus is dropped.
            DispatchQueue.main.async { keyboardFocused = true }
        }
        .onChange(of: sourceID) { _, _ in
            load()
            reloadSavedClips()
            DispatchQueue.main.async { keyboardFocused = true }
        }
        .onChange(of: appState.libraryRevision) { _, _ in reloadSavedClips() }
        .onDisappear { controller.tearDown() }
        .onKeyPress("i") { markIn(); return .handled }
        .onKeyPress("o") { markOut(); return .handled }
        .onKeyPress("s") { saveRange(); return .handled }
        .onKeyPress(.space) { controller.togglePlayPause(); return .handled }
        // Plain arrows: frame-accurate single-frame step.
        // Shift+arrow: 5-second jump for fast scrubbing.
        // J / L (industry-standard transport keys): also 5s jump.
        .onKeyPress(keys: [.leftArrow]) { press in
            if press.modifiers.contains(.shift) { controller.jumpBackward(seconds: 5) }
            else { controller.stepBackward() }
            return .handled
        }
        .onKeyPress(keys: [.rightArrow]) { press in
            if press.modifiers.contains(.shift) { controller.jumpForward(seconds: 5) }
            else { controller.stepForward() }
            return .handled
        }
        .onKeyPress("j") { controller.jumpBackward(seconds: 5); return .handled }
        .onKeyPress("l") { controller.jumpForward(seconds: 5); return .handled }
        .onKeyPress("k") { controller.togglePlayPause(); return .handled }
        // Menu commands and command palette post these notifications. We observe
        // them here so the menu drives whichever player is currently visible.
        .onReceive(NotificationCenter.default.publisher(for: .markIn)) { _ in markIn() }
        .onReceive(NotificationCenter.default.publisher(for: .markOut)) { _ in markOut() }
        .onReceive(NotificationCenter.default.publisher(for: .saveRange)) { _ in saveRange() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepBack)) { _ in controller.stepBackward() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepForward)) { _ in controller.stepForward() }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            // Transport cluster: -5s | prev frame | play/pause | next frame | +5s
            HStack(spacing: 4) {
                Button { controller.jumpBackward(seconds: 5) } label: {
                    Image(systemName: "gobackward.5").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Back 5s (J or ⇧←)")

                Button { controller.stepBackward() } label: {
                    Image(systemName: "backward.frame.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Previous frame (←)")

                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.borderless)
                .help("Play / Pause (Space or K)")

                Button { controller.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Next frame (→)")

                Button { controller.jumpForward(seconds: 5) } label: {
                    Image(systemName: "goforward.5").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Forward 5s (L or ⇧→)")
            }

            // Time display
            HStack(spacing: 4) {
                Text(controller.currentTimeLabel)
                    .monospacedDigit().font(.system(.body, design: .monospaced))
                    .fixedSize()
                Text("/").foregroundStyle(.tertiary)
                Text(controller.durationLabel)
                    .monospacedDigit().font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            // In/Out range indicator
            if let inMs = appState.playerInMs {
                HStack(spacing: 4) {
                    Image(systemName: "scissors").font(.caption2)
                    Text(PlayerController.formatMs(inMs))
                        .font(.caption.monospacedDigit())
                    if let outMs = appState.playerOutMs {
                        Text("→")
                        Text(PlayerController.formatMs(outMs))
                            .font(.caption.monospacedDigit())
                        Text("(\(PlayerController.formatMs(outMs - inMs)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.green)
                .fixedSize()
            }

            Spacer()

            // Mark cluster
            HStack(spacing: 6) {
                Button { markIn() } label: {
                    Label("In", systemImage: "i.square")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("Mark In (I)")
                Button { markOut() } label: {
                    Label("Out", systemImage: "o.square")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("Mark Out (O)")
                Button { saveRange() } label: {
                    Label("Save Clip", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [])
                .help("Save range as clip (S)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func load() {
        do {
            guard let src: Source = try AppEnvironment.shared.database.read({
                try Source.fetchOne($0, key: sourceID)
            }) else { return }
            self.source = src
            controller.load(url: src.url)
            if let inMs = appState.playerInMs {
                controller.seek(toMs: inMs)
            }
        } catch {
            NSLog("PlayerView.load failed: \(error)")
        }
    }

    private func markIn() {
        appState.playerInMs = controller.currentMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    private func markOut() {
        appState.playerOutMs = controller.currentMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    private func saveRange() {
        guard let inMs = appState.playerInMs, let outMs = appState.playerOutMs else {
            AppState.shared.showToast("Mark in and out points first (I, O)", level: .warning)
            return
        }
        do {
            _ = try AppEnvironment.shared.markerStore.saveRange(
                sourceID: sourceID, inMs: inMs, outMs: outMs
            )
            // Show the running count so the user gets a sense of progress on
            // this source. Reload happens via libraryRevision observer.
            let count = savedClips.count + 1
            AppState.shared.showToast(
                "Saved clip \(count) (\(PlayerController.formatMs(outMs - inMs)))",
                level: .success
            )
            // Park the playhead just after the out point so the user can
            // immediately mark the next clip's in/out without re-scrubbing.
            controller.seek(toMs: outMs)
            appState.playerInMs = nil
            appState.playerOutMs = nil
        } catch {
            AppState.shared.showToast("Failed to save: \(error.localizedDescription)", level: .error)
        }
    }

    private func reloadSavedClips() {
        Task.detached(priority: .userInitiated) { [sourceID] in
            let env = AppEnvironment.shared
            guard let store = env.markerStore else { return }
            let clips = (try? store.fetchClips(forSource: sourceID)) ?? []
            await MainActor.run { self.savedClips = clips }
        }
    }

    /// Horizontal scrolling strip listing every clip already saved from this
    /// source. Click → load its range; double-click → also start playback.
    private var savedClipsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Clips from this source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(savedClips.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    AppState.shared.showToast(
                        "I = mark in · O = mark out · S = save · J/L = ±5s",
                        level: .info
                    )
                } label: {
                    Image(systemName: "info.circle").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Keyboard shortcuts")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedClips, id: \.id) { clip in
                        savedClipChip(clip)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .background(.bar)
    }

    private func savedClipChip(_ clip: Clip) -> some View {
        let isSelected = appState.selectedClipIDs.contains(clip.id ?? -1)
        return Button {
            if let id = clip.id { appState.selectedClipIDs = [id] }
            appState.playerInMs = clip.inMs
            appState.playerOutMs = clip.outMs
            controller.seek(toMs: clip.inMs)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(clip.name ?? "Clip \(clip.id ?? 0)")
                    .font(.caption)
                    .lineLimit(1)
                Text(PlayerController.formatMs(clip.outMs - clip.inMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Inspector") {
                if let id = clip.id {
                    appState.selectedClipIDs = [id]
                    appState.inspectorVisible = true
                }
            }
            Divider()
            Button("Export as Reels") {
                if let id = clip.id { exportClip(id, preset: .reels) }
            }
            Button("Export as YouTube 1080p") {
                if let id = clip.id { exportClip(id, preset: .youtube1080p) }
            }
            Divider()
            Button("Delete clip", role: .destructive) {
                if let id = clip.id { deleteClip(id) }
            }
        }
    }

    private func exportClip(_ clipID: Int64, preset: ExportPreset) {
        appState.selectedClipIDs = [clipID]
        ExportActions.exportSelected(preset)
    }

    private func deleteClip(_ clipID: Int64) {
        do {
            try AppEnvironment.shared.markerStore.deleteClip(clipID)
            appState.selectedClipIDs.remove(clipID)
            AppState.shared.showToast("Clip deleted", level: .info)
        } catch {
            AppState.shared.showToast("Delete failed: \(error.localizedDescription)", level: .error)
        }
    }
}

/// Wraps AVPlayerLayer in an NSViewRepresentable so SwiftUI can host it.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerSurfaceView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.playerLayer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = (nsView as? PlayerSurfaceView)?.playerLayer {
            layer.player = player
        }
    }
}

final class PlayerSurfaceView: NSView {
    var playerLayer: AVPlayerLayer?
    override var isFlipped: Bool { true }
    // Tell AppKit the view has no preferred size — fill whatever the parent
    // gives us. Without this, AVPlayerLayer's content size leaks through and
    // demands the video's native dimensions (e.g. 1920 wide for 1080p),
    // pushing the SwiftUI detail column off-screen.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
}
