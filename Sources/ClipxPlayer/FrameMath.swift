import Foundation

/// Frame ↔ time math for frame-accurate stepping and marking.
///
/// The bug (#14): stepping accumulated truncated milliseconds
/// (`currentMs += Int64(1000/fps)`), so at 23.976 fps each step lost ~0.7 ms
/// and 20 steps drifted ~half a frame; step-forward-then-back didn't return to
/// the same frame, and marks landed off the displayed frame.
///
/// The fix: always work from the *frame index*. A time is snapped to its
/// nearest frame, and stepping moves whole frame indices — so there's nothing
/// to accumulate and round-trips are exact.
enum FrameMath {
    /// Nearest frame index for a time given in milliseconds.
    static func frameIndex(ms: Int64, fps: Double) -> Int64 {
        guard fps > 0 else { return 0 }
        return Int64((Double(ms) / 1000.0 * fps).rounded())
    }

    /// The millisecond start of a given frame index.
    static func msForFrame(_ index: Int64, fps: Double) -> Int64 {
        guard fps > 0 else { return 0 }
        return Int64((Double(index) / fps * 1000.0).rounded())
    }

    /// Snap a millisecond time onto the nearest frame boundary. Used when
    /// capturing in/out marks so they correspond to the displayed frame. (#14)
    static func snapToFrame(ms: Int64, fps: Double) -> Int64 {
        msForFrame(frameIndex(ms: ms, fps: fps), fps: fps)
    }

    /// Result of stepping `frames` (±) from a time, computed in frame space so
    /// repeated steps never accumulate rounding error. Floors at frame 0. (#14)
    static func steppedMs(fromMs current: Int64, frames: Int, fps: Double) -> Int64 {
        guard fps > 0 else { return max(0, current) }
        let target = max(0, frameIndex(ms: current, fps: fps) + Int64(frames))
        return msForFrame(target, fps: fps)
    }
}
