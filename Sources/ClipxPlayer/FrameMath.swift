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
        guard fps.isFinite, fps > 0 else { return 0 }
        return saturatedInteger((Double(max(0, ms)) / 1000.0 * fps).rounded())
    }

    /// The millisecond start of a given frame index.
    static func msForFrame(_ index: Int64, fps: Double) -> Int64 {
        guard fps.isFinite, fps > 0 else { return 0 }
        return saturatedInteger((Double(max(0, index)) / fps * 1000.0).rounded())
    }

    /// Snap a millisecond time onto the nearest frame boundary. Used when
    /// capturing in/out marks so they correspond to the displayed frame. (#14)
    static func snapToFrame(ms: Int64, fps: Double) -> Int64 {
        msForFrame(frameIndex(ms: ms, fps: fps), fps: fps)
    }

    /// Result of stepping `frames` (±) from a time, computed in frame space so
    /// repeated steps never accumulate rounding error. Floors at frame 0. (#14)
    static func steppedMs(fromMs current: Int64, frames: Int, fps: Double) -> Int64 {
        guard fps.isFinite, fps > 0 else { return max(0, current) }
        let (sum, overflow) = frameIndex(ms: current, fps: fps).addingReportingOverflow(Int64(frames))
        let target = overflow ? (frames > 0 ? Int64.max : 0) : max(0, sum)
        return msForFrame(target, fps: fps)
    }

    static func rangeDuration(inMs: Int64, outMs: Int64) -> Int64 {
        guard inMs >= 0, outMs > inMs else { return 0 }
        return outMs - inMs
    }

    static func totalDuration(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            return overflow ? .max : sum
        }
    }

    private static func saturatedInteger(_ value: Double) -> Int64 {
        guard !value.isNaN, value > 0 else { return 0 }
        if value >= Double(Int64.max) { return .max }
        return Int64(value)
    }
}
