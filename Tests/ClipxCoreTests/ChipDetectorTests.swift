import XCTest
@testable import Clipx

final class ChipDetectorTests: XCTestCase {
    func test_detect_returnsKnownTier() {
        let tier = ChipDetector.detect()
        // Just verify it returns a known value (we can't assert specific tier
        // without knowing the test runner's hardware).
        let known: [ChipDetector.Tier] = [.appleSiliconBase, .appleSiliconProMax, .intel, .unknown]
        XCTAssertTrue(known.contains(tier))
    }

    func test_recommendedH264_isOneOfKnownCodecs() {
        let codec = ChipDetector.recommendedH264Codec()
        XCTAssertTrue(["h264_videotoolbox", "libx264"].contains(codec))
    }
}
