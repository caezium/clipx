import Foundation
import AVFoundation
import SwiftUI
import Combine

/// Observable AVPlayer wrapper with frame-accurate seek + frame-stepping.
///
/// All UI-mutating state writes happen on the main actor. Background metadata
/// loads (`fps`, `aspectRatio`) explicitly hop back via `MainActor.run` — the
/// previous version wrote those properties from a non-isolated Task, which
/// raced with `stepForward()` reading them.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published var aspectRatio: CGFloat = 16.0 / 9.0

    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private(set) var fps: Float = 30.0

    init() {}

    func load(url: URL) {
        tearDown()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        installPeriodicObserver(player: player, fps: fps)

        Task { [weak self] in
            do {
                let duration = try await asset.load(.duration)
                let ms = Int64(CMTimeGetSeconds(duration) * 1000)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var newFps: Float = 30.0
                var newAspect: CGFloat = 16.0 / 9.0
                if let track = tracks.first {
                    let size = try await track.load(.naturalSize)
                    if size.height > 0 {
                        newAspect = size.width / size.height
                    }
                    let rate = try await track.load(.nominalFrameRate)
                    newFps = rate > 0 ? rate : 30.0
                }
                await MainActor.run {
                    guard let self else { return }
                    self.durationMs = ms
                    self.fps = newFps
                    self.aspectRatio = newAspect
                    self.installPeriodicObserver(player: player, fps: newFps)
                }
            } catch {
                ClipxLog.player.debug("metadata load failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func tearDown() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentMs = 0
        durationMs = 0
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Frame-accurate seek using zero tolerance.
    func seek(toMs ms: Int64) {
        guard let player else { return }
        let time = CMTime(value: ms, timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepForward() {
        guard let player, fps > 0 else { return }
        _ = player
        let frameDuration = 1.0 / Double(fps)
        let nextMs = currentMs + Int64(frameDuration * 1000)
        seek(toMs: nextMs)
    }

    func stepBackward() {
        guard let player, fps > 0 else { return }
        _ = player
        let frameDuration = 1.0 / Double(fps)
        let prevMs = max(0, currentMs - Int64(frameDuration * 1000))
        seek(toMs: prevMs)
    }

    /// Jump forward by N seconds. Caps at duration.
    func jumpForward(seconds: Double) {
        guard player != nil else { return }
        let next = currentMs + Int64(seconds * 1000)
        let target = durationMs > 0 ? min(next, durationMs) : next
        seek(toMs: target)
    }

    /// Jump backward by N seconds. Floors at 0.
    func jumpBackward(seconds: Double) {
        guard player != nil else { return }
        let prev = currentMs - Int64(seconds * 1000)
        seek(toMs: max(0, prev))
    }

    var currentTimeLabel: String { Self.formatMs(currentMs) }
    var durationLabel: String { Self.formatMs(durationMs) }

    /// (Re)installs the periodic time observer at the source's frame rate, so
    /// 60p sources don't lose updates and 24p sources don't over-poll.
    /// Previously hardcoded to 30 Hz.
    private func installPeriodicObserver(player: AVPlayer, fps: Float) {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        // Clamp to a reasonable visible refresh range — fractional fps like
        // 23.976 round to 24, but extreme rates (slow-mo 240) get clamped
        // back to 60 to avoid pegging the UI thread.
        let timescale = CMTimeScale(min(60, max(24, Int(fps.rounded()))))
        let interval = CMTime(value: 1, timescale: timescale)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            self?.currentMs = Int64(CMTimeGetSeconds(t) * 1000)
        }
    }

    static func formatMs(_ ms: Int64) -> String {
        let totalMs = max(0, ms)
        let h = Int(totalMs / 3_600_000)
        let m = Int((totalMs / 60_000) % 60)
        let s = Int((totalMs / 1000) % 60)
        let cs = Int((totalMs / 10) % 100)
        if h > 0 {
            return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
        }
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}
