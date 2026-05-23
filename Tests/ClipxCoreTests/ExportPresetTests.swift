import XCTest
@testable import Clipx

final class ExportPresetTests: XCTestCase {
    func test_allBuiltInPresetsHaveDistinctIDs() {
        let ids = ExportPreset.allBuiltIn.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func test_reelsPresetIsPortrait1080x1920() {
        XCTAssertEqual(ExportPreset.reels.width, 1080)
        XCTAssertEqual(ExportPreset.reels.height, 1920)
        XCTAssertEqual(ExportPreset.reels.containerExt, "mp4")
        XCTAssertEqual(ExportPreset.reels.lufsTarget, -10)
    }

    func test_youtube4kIsAt3840x2160() {
        XCTAssertEqual(ExportPreset.youtube4k.width, 3840)
        XCTAssertEqual(ExportPreset.youtube4k.height, 2160)
        XCTAssertEqual(ExportPreset.youtube4k.lufsTarget, -14)
    }

    func test_instagramFeedIs4to5() {
        let p = ExportPreset.instagramFeed
        XCTAssertEqual(Double(p.width) / Double(p.height), 1080.0 / 1350.0)
    }

    #if DIRECT_BUILD
    func test_ffmpegArguments_includeLoudnormForReels() {
        let args = FFmpegBackend.buildArguments(
            sourcePath: "/tmp/in.mov",
            inMs: 1000, outMs: 5000,
            preset: .reels, outputPath: "/tmp/out.mp4"
        )
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("loudnorm=I=-10.0"))
        XCTAssertTrue(joined.contains("1080:1920"))
        XCTAssertTrue(joined.contains("-color_primaries bt709"))
    }

    func test_ffmpegArguments_includeSeekAndDurationInSeconds() {
        let args = FFmpegBackend.buildArguments(
            sourcePath: "/tmp/in.mov",
            inMs: 1500, outMs: 4500,
            preset: .youtube1080p, outputPath: "/tmp/out.mp4"
        )
        XCTAssertTrue(args.contains("-ss"))
        XCTAssertTrue(args.contains("1.500"))
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("3.000"))
    }
    #endif
}
