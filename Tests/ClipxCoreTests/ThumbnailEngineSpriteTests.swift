import XCTest
import AVFoundation
import CoreVideo
import AppKit
@testable import Clipx

/// Regression test for the `generateSprite` refactor (branch fix/backlog-tdd).
///
/// `generateSprite` is currently engine-only (no UI/server caller), so this is
/// the only thing that exercises the path. It guards against a return of the
/// original anti-pattern: the method used to run its whole body in
/// `Task.detached` and block a cooperative-pool thread with
/// `DispatchSemaphore.wait()`. That starves the pool and, under the Swift 6
/// language mode, fails to compile. The fix dispatches the blocking work onto
/// the real `queue` DispatchQueue and bridges the async duration load with a
/// semaphore — mirroring `generateSync`.
///
/// We assert the observable contract: a real video in → a valid
/// (240·frameCount)×135 JPEG sprite strip out, with completion on the main
/// thread. If generation ever deadlocks, the expectation times out and fails.
final class ThumbnailEngineSpriteTests: XCTestCase {

    func test_generateSprite_producesMainThreadSpriteStrip() throws {
        // A real, decodable ~2s clip so AVAssetImageGenerator has frames to pull.
        let videoURL = try Self.makeTestVideo(seconds: 2.0, width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let db = try Database.inMemory()
        let engine = ThumbnailEngine(database: db)

        // Unique hash so we never hit the file-exists fast path or collide with
        // a real cache entry — this must drive the generation code path.
        let hash = "spritetest" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let source = Source(
            id: 1, path: videoURL.path, bookmark: nil,
            hash: hash, mtime: 0, durationMs: nil,
            width: nil, height: nil, fps: nil, codec: nil,
            audioChannels: nil, colorSpace: nil, createdAt: nil,
            importedAt: 0, thumbPath: nil, online: true, notes: nil
        )
        let spritePath = engine.spritePath(for: hash)
        try? FileManager.default.removeItem(at: spritePath)
        defer { try? FileManager.default.removeItem(at: spritePath) }

        let frameCount = 10
        let done = expectation(description: "sprite generated")
        var resultURL: URL?
        var completedOnMain = false
        engine.generateSprite(source: source, frameCount: frameCount) { url in
            completedOnMain = Thread.isMainThread
            resultURL = url
            done.fulfill()
        }
        // Generous ceiling: synth + 10-frame extraction is a few seconds. A
        // deadlock (the old anti-pattern) would blow past this.
        wait(for: [done], timeout: 30)

        XCTAssertTrue(completedOnMain, "completion must fire on the main thread")
        let url = try XCTUnwrap(resultURL, "generateSprite returned nil for a valid video")
        XCTAssertEqual(url, spritePath, "sprite must be written to spritePath(for:)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "sprite file not written")

        // The output must be a valid JPEG strip of exactly frameCount frames
        // at the documented 240×135 tile size.
        let data = try Data(contentsOf: url)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data), "sprite is not a decodable image")
        XCTAssertEqual(rep.pixelsWide, 240 * frameCount, "sprite strip width = 240 · frameCount")
        XCTAssertEqual(rep.pixelsHigh, 135, "sprite strip height = 135")
    }

    // MARK: - Test video synthesis

    /// Writes a short H.264 .mov (solid gray, brightness varying per frame so
    /// the encoder produces distinct frames) and returns its URL.
    private static func makeTestVideo(seconds: Double, width: Int, height: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipx-sprite-src-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "ThumbnailEngineSpriteTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add writer input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ThumbnailEngineSpriteTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let totalFrames = max(2, Int(seconds * Double(fps)))
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let pixelBuffer = try makePixelBuffer(width: width, height: height,
                                                  frame: i, total: totalFrames)
            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw writer.error ?? NSError(domain: "ThumbnailEngineSpriteTests", code: 3)
            }
        }
        input.markAsFinished()

        // finishWriting's handler runs off-main, so blocking the test thread on
        // this semaphore is safe (no main run-loop dependency).
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ThumbnailEngineSpriteTests", code: 4,
                                          userInfo: [NSLocalizedDescriptionKey: "writer status \(writer.status.rawValue)"])
        }
        return url
    }

    private static func makePixelBuffer(width: Int, height: Int, frame: Int, total: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "ThumbnailEngineSpriteTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (\(status))"])
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            // Solid gray; value walks per frame so frames aren't identical.
            let value = Int32(30 + (frame * 9) % 200)
            memset(base, value, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        return buffer
    }
}
