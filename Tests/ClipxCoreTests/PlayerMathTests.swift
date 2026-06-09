import XCTest
@testable import Clipx

/// Frame-accurate stepping/marking math. (#14)
final class PlayerMathTests: XCTestCase {
    private let fps = 24000.0 / 1001.0   // 23.976 — the classic drift case

    func test_frameStep_roundTripsExactly() {
        var ms: Int64 = 0
        for _ in 0..<20 { ms = FrameMath.steppedMs(fromMs: ms, frames: 1, fps: fps) }
        for _ in 0..<20 { ms = FrameMath.steppedMs(fromMs: ms, frames: -1, fps: fps) }
        XCTAssertEqual(ms, 0, "20 steps forward then back must return to frame 0")
    }

    func test_frameStep_doesNotDrift() {
        var ms: Int64 = 0
        for _ in 0..<24 { ms = FrameMath.steppedMs(fromMs: ms, frames: 1, fps: fps) }
        XCTAssertEqual(FrameMath.frameIndex(ms: ms, fps: fps), 24)
        XCTAssertEqual(ms, 1001, "24 frames lands on true ~1001ms, not the drifted 24×41=984")
    }

    func test_snapToFrame_landsOnGridAndIsIdempotent() {
        let snapped = FrameMath.snapToFrame(ms: 40, fps: fps)   // ~0.96 of a frame → frame 1
        XCTAssertEqual(snapped, 42)
        XCTAssertEqual(FrameMath.snapToFrame(ms: snapped, fps: fps), snapped)
    }

    func test_frameMath_safeAtZeroFPS() {
        XCTAssertEqual(FrameMath.steppedMs(fromMs: 500, frames: 1, fps: 0), 500)
        XCTAssertEqual(FrameMath.snapToFrame(ms: 500, fps: 0), 0)
    }
}
