import SwiftUI
import AVKit
import AVFoundation

/// Built-in player with frame-accurate scrubbing and I/O marking hotkeys.
struct PlayerView: View {
    let sourceID: Int64
    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = PlayerController()
    @State private var source: Source?

    var body: some View {
        VStack(spacing: 0) {
            if let player = controller.player {
                PlayerSurface(player: player)
                    .background(.black)
                    .aspectRatio(controller.aspectRatio, contentMode: .fit)
            } else {
                Rectangle().fill(.black).aspectRatio(16/9, contentMode: .fit)
            }
            TimelineStripView(controller: controller)
                .frame(height: 60)
            controlBar
        }
        .focusable()
        .onAppear { load() }
        .onChange(of: sourceID) { _, _ in load() }
        .onDisappear { controller.tearDown() }
        .onKeyPress("i") { markIn(); return .handled }
        .onKeyPress("o") { markOut(); return .handled }
        .onKeyPress("s") { saveRange(); return .handled }
        .onKeyPress(.space) { controller.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { controller.stepBackward(); return .handled }
        .onKeyPress(.rightArrow) { controller.stepForward(); return .handled }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button { controller.stepBackward() } label: {
                Image(systemName: "backward.frame.fill")
            }
            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { controller.stepForward() } label: {
                Image(systemName: "forward.frame.fill")
            }
            Spacer()
            Text(controller.currentTimeLabel).monospacedDigit().font(.caption)
            Text("/").foregroundStyle(.secondary)
            Text(controller.durationLabel).monospacedDigit().font(.caption)
            Spacer()
            Button { markIn() } label: { Text("Mark In (I)") }
            Button { markOut() } label: { Text("Mark Out (O)") }
            Button { saveRange() } label: { Text("Save (S)") }
                .keyboardShortcut("s", modifiers: [])
        }
        .padding(8)
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
            AppState.shared.showToast("Saved clip range", level: .success)
            appState.playerInMs = nil
            appState.playerOutMs = nil
        } catch {
            AppState.shared.showToast("Failed to save: \(error.localizedDescription)", level: .error)
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
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
}
