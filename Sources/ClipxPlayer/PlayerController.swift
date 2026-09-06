import Foundation
import AVFoundation
import SwiftUI
import Combine

/// High-frequency playback clock, deliberately split out of `PlayerController`.
///
/// During playback the time observer fires 24–60×/second. If `currentMs` lived
/// on `PlayerController` (which the whole player UI observes), every tick would
/// invalidate the control bar, the filmstrip, and every saved-clip pin on the
/// timeline. Views that only need the moving time (the playhead, the time
/// read-out) observe *just this* object instead, so the heavy, static parts of
/// the UI render once and stay put.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentMs: Int64 = 0
}

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
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// The moving playhead time, on its own observable so per-frame updates
    /// don't re-render the rest of the player UI. Read `currentMs` for the value.
    let clock = PlaybackClock()
    var currentMs: Int64 { clock.currentMs }
    @Published private(set) var durationMs: Int64 = 0
    @Published var aspectRatio: CGFloat = 16.0 / 9.0
    /// Display rotation (degrees CW) applied to the preview via a video composition.
    @Published private(set) var rotation: Int = 0
    /// Permanent per-source playback speed (e.g. 4× for slow-mo footage). Applied
    /// to the preview and baked into exports. 1.0 = original speed.
    @Published private(set) var speed: Double = 1.0
    /// Playback volume 0…1 (preview only; persists across sources).
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var muted: Bool = false

    /// Transient multiplier for hold-to-speed (Space / click-hold). 1.0 = off.
    private var heldMultiplier: Double = 1.0

    private var timeObserver: (player: AVPlayer, token: Any)?
    private var endObserver: NSObjectProtocol?
    private var metadataTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadGeneration = UUID()
    private var asset: AVURLAsset?
    private(set) var fps: Float = 30.0

    init() {}

    func load(url: URL) {
        tearDown()
        let asset = AVURLAsset(url: url)
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        let generation = loadGeneration
        isLoading = true
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == generation, self.player?.currentItem === observed else { return }
                if observed.status == .failed {
                    self.loadError = observed.error?.localizedDescription ?? "This video couldn't be played."
                    self.isLoading = false
                    self.pause()
                }
            }
        }
        applyVolume()   // handles boost (>1) via audio mix once the item exists
        installPeriodicObserver(player: player, fps: fps)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                            object: item, queue: .main) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, self.player === player, self.loadGeneration == generation else { return }
                self.isPlaying = false
                self.heldMultiplier = 1
                self.clock.currentMs = self.durationMs
            }
        }

        metadataTask = Task { [weak self] in
            do {
                let duration = try await asset.load(.duration)
                let ms = Self.milliseconds(duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var newFps: Float = 30.0
                var newAspect: CGFloat = 16.0 / 9.0
                if let track = tracks.first {
                    let size = try await track.load(.naturalSize)
                    if size.height.isFinite, size.width.isFinite, size.width > 0, size.height > 0 {
                        newAspect = size.width / size.height
                    }
                    let rate = try await track.load(.nominalFrameRate)
                    newFps = rate.isFinite && rate > 0 ? rate : 30.0
                }
                await MainActor.run {
                    guard let self, !Task.isCancelled, self.loadGeneration == generation,
                          self.player === player else { return }
                    self.durationMs = ms
                    self.fps = newFps
                    self.aspectRatio = newAspect
                    self.isLoading = false
                    self.installPeriodicObserver(player: player, fps: newFps)
                }
            } catch {
                guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
                ClipxLog.player.debug("metadata load failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func tearDown() {
        loadGeneration = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        itemStatusObservation = nil
        if let obs = timeObserver { obs.player.removeTimeObserver(obs.token) }
        timeObserver = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        player?.pause()
        player = nil
        asset = nil
        rotation = 0
        speed = 1.0
        heldMultiplier = 1.0
        isPlaying = false
        isLoading = false
        loadError = nil
        clock.currentMs = 0
        durationMs = 0
        fps = 30
        aspectRatio = 16.0 / 9.0
    }

    /// Set the preview rotation (degrees CW) and apply it via a video
    /// composition on the current item.
    func setRotation(_ degrees: Int) {
        rotation = VideoRotation.normalized(degrees)
        applyRotationComposition()
    }

    private func applyRotationComposition() {
        guard let item = player?.currentItem else { return }
        let degrees = rotation
        if degrees == 0 { item.videoComposition = nil; return }
        guard let asset else { return }
        Task { [weak self] in
            let comp = await Self.rotationComposition(asset: asset, degrees: degrees)
            await MainActor.run {
                guard let self, self.rotation == degrees, self.player?.currentItem === item else { return }
                item.videoComposition = comp
            }
        }
    }

    nonisolated private static func rotationComposition(asset: AVURLAsset, degrees: Int) async -> AVMutableVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return nil }
        let preferred = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = natural.applying(preferred)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        var t = preferred
        t = t.concatenating(VideoRotation.transform(oriented: orientedSize, degrees: degrees))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: (try? await asset.load(.duration)) ?? .zero)
        instruction.layerInstructions = [layer]
        let comp = AVMutableVideoComposition()
        comp.renderSize = VideoRotation.renderSize(oriented: orientedSize, degrees: degrees)
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        let safeRate = min(Double(Int32.max), max(24, fps.isFinite ? Double(fps.rounded()) : 30))
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeRate))
        comp.instructions = [instruction]
        return comp
    }

    func togglePlayPause() {
        guard let player, loadError == nil else { return }
        if !isPlaying, durationMs > 0, currentMs >= durationMs - 1 {
            let generation = loadGeneration
            isPlaying = true
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, finished, self.player === player,
                          self.loadGeneration == generation, self.isPlaying else { return }
                    self.clock.currentMs = 0
                    self.applyRate()
                }
            }
            return
        }
        isPlaying.toggle()
        applyRate()
    }

    func pause() {
        isPlaying = false
        applyRate()
    }

    /// Apply the effective playback rate: speed × any held multiplier while
    /// playing, or 0 while paused. All play/pause/speed paths funnel here so
    /// rate stays consistent.
    private func applyRate() {
        guard let player else { return }
        player.rate = isPlaying ? Float(max(0.05, speed * heldMultiplier)) : 0
    }

    // MARK: - Permanent per-source speed

    /// Max playback speed — high enough for very-high-fps slow-mo (e.g. 960fps
    /// → ~32×, but capped to a sane preview/export ceiling).
    static let maxSpeed: Double = 16.0

    /// Set the permanent playback speed (also baked into exports by the caller).
    func setSpeed(_ newSpeed: Double) {
        guard newSpeed.isFinite else { return }
        speed = max(0.1, min(Self.maxSpeed, newSpeed))
        applyRate()
    }

    // MARK: - Hold-to-speed (Space / click-hold)

    /// Engage a transient speed multiplier and ensure playback (idempotent).
    func beginHoldSpeed(_ multiplier: Double = 2.0) {
        guard player != nil, multiplier.isFinite, heldMultiplier == 1.0 else { return }
        heldMultiplier = max(1.0, multiplier)
        isPlaying = true
        applyRate()
    }

    /// Release the transient multiplier, returning to the permanent speed.
    func endHoldSpeed() {
        guard heldMultiplier != 1.0 else { return }
        heldMultiplier = 1.0
        applyRate()
    }

    // MARK: - Volume

    /// Max volume — above 1.0 boosts the source gain (can clip loud material).
    static let maxVolume: Double = 2.0

    func setVolume(_ v: Double) {
        guard v.isFinite else { return }
        volume = max(0, min(Self.maxVolume, v))
        muted = false
        applyVolume()
    }

    func toggleMute() {
        muted.toggle()
        applyVolume()
    }

    /// Apply volume. AVPlayer.volume caps at 1.0, so gains above source use an
    /// audio mix on the current item (its input gain multiplies player.volume).
    private func applyVolume() {
        guard let player else { return }
        let v = muted ? 0 : volume
        player.volume = Float(min(1.0, v))
        guard let item = player.currentItem else { return }
        guard v > 1.0, let asset else { item.audioMix = nil; return }
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(v), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            await MainActor.run {
                guard let self, self.player?.currentItem === item,
                      !self.muted, self.volume == v else { return }
                item.audioMix = mix
            }
        }
    }

    /// Frame-accurate seek using zero tolerance.
    func seek(toMs ms: Int64) {
        guard let player else { return }
        let target = max(0, durationMs > 0 ? min(ms, durationMs) : ms)
        let time = CMTime(value: target, timescale: 1000)
        clock.currentMs = target
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Millisecond time of the frame currently displayed — marks should use
    /// this so they land on the frame the user saw, not a rounded ms. (#14)
    var currentFrameMs: Int64 {
        let snapped = FrameMath.snapToFrame(ms: currentMs, fps: Double(fps))
        return durationMs > 0 ? min(durationMs, snapped) : snapped
    }

    func stepForward() {
        guard player != nil, fps > 0 else { return }
        // Step in frame space so repeated steps don't accumulate ms rounding. (#14)
        seek(toMs: FrameMath.steppedMs(fromMs: currentMs, frames: 1, fps: Double(fps)))
    }

    func stepBackward() {
        guard player != nil, fps > 0 else { return }
        seek(toMs: FrameMath.steppedMs(fromMs: currentMs, frames: -1, fps: Double(fps)))
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

    var durationLabel: String { Self.formatMs(durationMs) }

    /// (Re)installs the periodic time observer at the source's frame rate, so
    /// 60p sources don't lose updates and 24p sources don't over-poll.
    /// Previously hardcoded to 30 Hz.
    private func installPeriodicObserver(player: AVPlayer, fps: Float) {
        if let obs = timeObserver {
            obs.player.removeTimeObserver(obs.token)
            timeObserver = nil
        }
        // Clamp to a reasonable visible refresh range — fractional fps like
        // 23.976 round to 24, but extreme rates (slow-mo 240) get clamped
        // back to 60 to avoid pegging the UI thread.
        let timescale = CMTimeScale(min(60, max(24, fps.isFinite ? fps.rounded() : 30)))
        let interval = CMTime(value: 1, timescale: timescale)
        let generation = loadGeneration
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] t in
            Task { @MainActor in
                guard let self, self.player === player, self.loadGeneration == generation else { return }
                self.clock.currentMs = Self.milliseconds(t)
            }
        }
        timeObserver = (player, token)
    }

    private static func milliseconds(_ time: CMTime) -> Int64 {
        let value = CMTimeGetSeconds(time) * 1000
        guard value.isFinite, value > 0, value < Double(Int64.max) else { return 0 }
        return Int64(value.rounded())
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
