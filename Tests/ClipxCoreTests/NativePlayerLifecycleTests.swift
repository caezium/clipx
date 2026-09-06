import XCTest
import AVFoundation
import CoreVideo
@testable import Clipx

final class NativePlayerLifecycleTests: XCTestCase {
    @MainActor
    func test_rapidLoadsPublishOnlyCurrentAssetAndObserverTeardownIsSafe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let short = try await movie(at: directory.appendingPathComponent("short.mov"), frameCount: 6)
        let long = try await movie(at: directory.appendingPathComponent("long.mov"), frameCount: 18)
        let controller = PlayerController()
        controller.load(url: directory.appendingPathComponent("missing.mov"))
        for _ in 0..<20 {
            controller.load(url: short)
            controller.load(url: long)
        }
        try await waitUntil { controller.durationMs == 1500 }
        XCTAssertEqual((controller.player?.currentItem?.asset as? AVURLAsset)?.url, long)
        XCTAssertNil(controller.loadError)
        controller.tearDown()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(controller.player)
        XCTAssertEqual(controller.durationMs, 0)
        XCTAssertEqual(controller.currentMs, 0)
    }

    @MainActor
    func test_missingVideoReportsFailureAndTeardownClearsIt() async throws {
        let controller = PlayerController()
        controller.load(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"))
        try await waitUntil { controller.loadError != nil }
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.isPlaying)
        controller.tearDown()
        XCTAssertNil(controller.loadError)
    }

    @MainActor
    func test_realPlaybackReachesEOFAndPlayRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await movie(at: directory.appendingPathComponent("end.mov"), frameCount: 6)
        let controller = PlayerController()
        defer { controller.tearDown() }
        controller.load(url: url)
        try await waitUntil { controller.durationMs > 0 && controller.player?.currentItem?.status == .readyToPlay }
        controller.togglePlayPause()
        try await waitUntil { !controller.isPlaying && controller.currentMs >= controller.durationMs }
        XCTAssertEqual(controller.player?.rate, 0)
        controller.togglePlayPause()
        try await waitUntil { controller.isPlaying && controller.currentMs < controller.durationMs && (controller.player?.rate ?? 0) > 0 }
        controller.pause()
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func test_seeksClampAndInvalidTransformInputsDoNotPoisonPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await movie(at: directory.appendingPathComponent("bounds.mov"), frameCount: 6)
        let controller = PlayerController()
        defer { controller.tearDown() }
        controller.load(url: url)
        try await waitUntil { controller.durationMs > 0 }
        controller.seek(toMs: -1)
        XCTAssertEqual(controller.currentMs, 0)
        controller.seek(toMs: .max)
        XCTAssertEqual(controller.currentMs, controller.durationMs)
        controller.setSpeed(.infinity)
        controller.setVolume(.nan)
        XCTAssertEqual(controller.speed, 1)
        XCTAssertEqual(controller.volume, 1)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Playback state did not reach the expected condition within five seconds")
    }

    private func movie(at url: URL, frameCount: Int) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(bytes, 100, CVPixelBufferGetBytesPerRow(pixelBuffer) * 32)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 12))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }
}
