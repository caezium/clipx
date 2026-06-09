import XCTest
import CoreGraphics
@testable import Clipx

private final class Counter: @unchecked Sendable { var n = 0 }

final class ExportBackendTests: XCTestCase {

    // MARK: #10 — synchronous canceller box

    func test_cancellerBox_firesSetClosure() {
        let box = CancellerBox()
        let c = Counter()
        box.set { c.n += 1 }
        box.cancel()
        XCTAssertEqual(c.n, 1)
    }

    func test_cancellerBox_clearedCancellerDoesNotFire() {
        let box = CancellerBox()
        let c = Counter()
        box.set { c.n += 1 }
        box.set(nil)
        box.cancel()
        XCTAssertEqual(c.n, 0, "a cleared canceller must not fire")
    }

    // MARK: #12 — shared fill+crop framing policy

    func test_framingPolicy_fillsAndCropsToExactDims() {
        // 16:9 source into a 9:16 target → scale to cover, crop the sides.
        let scale = FramingPolicy.fillScale(srcW: 1920, srcH: 1080, dstW: 1080, dstH: 1920)
        XCTAssertEqual(scale, 1920.0 / 1080.0, accuracy: 0.0001)   // height-driven
        let scaledW = 1920 * scale, scaledH = 1080 * scale
        XCTAssertGreaterThanOrEqual(scaledW, 1080)                 // covers width
        XCTAssertEqual(scaledH, 1920, accuracy: 0.5)               // exact height
        let off = FramingPolicy.centerOffset(scaledW: scaledW, scaledH: scaledH, dstW: 1080, dstH: 1920)
        XCTAssertLessThan(off.x, 0)                                // crops horizontally
        XCTAssertEqual(off.y, 0, accuracy: 0.5)
    }

    func test_framingPolicy_ffmpegFilterIsFillCrop() {
        XCTAssertEqual(FramingPolicy.ffmpegFilter(width: 1080, height: 1920),
                       "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920")
    }

    // MARK: #13 — ffmpeg progress parsing

    func test_ffmpegProgress_parsesLatestOutTimeAndFraction() {
        let chunk = "frame=10\nout_time_us=500000\nprogress=continue\nout_time_us=1000000\nprogress=continue\n"
        XCTAssertEqual(FFmpegProgress.latestOutTimeUs(chunk), 1_000_000)
        XCTAssertEqual(FFmpegProgress.fraction(outTimeUs: 1_000_000, durationSec: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FFmpegProgress.fraction(outTimeUs: 5_000_000, durationSec: 2), 1.0, "clamped to 1")
        XCTAssertNil(FFmpegProgress.latestOutTimeUs("no progress here"))
    }
}
