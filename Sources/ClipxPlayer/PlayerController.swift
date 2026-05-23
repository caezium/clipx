import Foundation
import AVFoundation
import SwiftUI
import Combine

/// Observable AVPlayer wrapper with frame-accurate seek + frame-stepping.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published var aspectRatio: CGFloat = 16.0 / 9.0

    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var fps: Float = 30.0

    init() {}

    func load(url: URL) {
        tearDown()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        Task {
            do {
                let duration = try await asset.load(.duration)
                let ms = Int64(CMTimeGetSeconds(duration) * 1000)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let size = try await track.load(.naturalSize)
                    if size.height > 0 {
                        self.aspectRatio = size.width / size.height
                    }
                    let rate = try await track.load(.nominalFrameRate)
                    self.fps = rate > 0 ? rate : 30.0
                }
                await MainActor.run { self.durationMs = ms }
            } catch {
                NSLog("PlayerController.load metadata failed: \(error)")
            }
        }

        let interval = CMTime(value: 1, timescale: 30) // ~33ms tick
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            self?.currentMs = Int64(CMTimeGetSeconds(t) * 1000)
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

    /// Frame-accurate seek using zero tolerance.
    func seek(toMs ms: Int64) {
        guard let player else { return }
        let time = CMTime(value: ms, timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepForward() {
        guard let player, fps > 0 else { return }
        let frameDuration = 1.0 / Double(fps)
        let nextMs = currentMs + Int64(frameDuration * 1000)
        seek(toMs: nextMs)
    }

    func stepBackward() {
        guard let player, fps > 0 else { return }
        let frameDuration = 1.0 / Double(fps)
        let prevMs = max(0, currentMs - Int64(frameDuration * 1000))
        seek(toMs: prevMs)
    }

    var currentTimeLabel: String { Self.formatMs(currentMs) }
    var durationLabel: String { Self.formatMs(durationMs) }

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
