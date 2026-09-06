import XCTest
import AVFoundation
import CoreVideo
@testable import Clipx

final class ServerProxyRegressionTests: XCTestCase {
    func test_failureIsTerminalUntilExplicitRetryAndRotationPreservesSourceTime() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipx-proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        let engine = WebProxyEngine(cacheDir: dir.appendingPathComponent("cache"), maxConcurrent: 1)
        await engine.startProxyIfNeeded(sourcePath: source.path, hash: "fixture", rotation: 90)
        let failed = try await waitUntilSettled(engine, hash: "fixture", rotation: 90)
        XCTAssertEqual(failed.state, "failed")
        XCTAssertNotNil(failed.error)

        try await makeVideo(at: source)
        await engine.startProxyIfNeeded(sourcePath: source.path, hash: "fixture", rotation: 90)
        let stillFailed = await engine.status(forHash: "fixture", rotation: 90)
        XCTAssertEqual(stillFailed.state, "failed", "Polling must not silently restart failed exports")
        await engine.startProxyIfNeeded(sourcePath: source.path, hash: "fixture", rotation: 90, retry: true)
        let ready = try await waitUntilSettled(engine, hash: "fixture", rotation: 90)
        XCTAssertTrue(ready.ready)
        let url = engine.proxyPath(forHash: "fixture", rotation: 90)
        XCTAssertNotEqual(url, engine.proxyPath(forHash: "fixture", rotation: 0))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.08, "Proxies keep source time; the browser applies speed")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 180)
        XCTAssertEqual(size.height, 320)
        await engine.shutdown()
    }

    func test_shutdownCancelsQueuedWorkAndRemovesPartialFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipx-proxy-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeVideo(at: source)
        let cache = dir.appendingPathComponent("cache")
        let engine = WebProxyEngine(cacheDir: cache, maxConcurrent: 1)
        for id in 0..<12 { await engine.startProxyIfNeeded(sourcePath: source.path, hash: "fixture-\(id)") }
        var preparing = 0, queued = 0
        for id in 0..<12 {
            let state = await engine.status(forHash: "fixture-\(id)")
            if state.state == "preparing" { preparing += 1 }
            if state.state == "queued" { queued += 1 }
        }
        XCTAssertLessThanOrEqual(preparing, 1)
        XCTAssertGreaterThan(queued, 0, "The queue must bound concurrent AVFoundation exports")
        await engine.shutdown()
        for id in 0..<12 {
            let state = await engine.status(forHash: "fixture-\(id)")
            XCTAssertFalse(["queued", "preparing"].contains(state.state))
        }
        // A cancelled AVFoundation export can still attempt a late output-file
        // open after its completion callback. Cleanup must prevent recreation.
        try await Task.sleep(nanoseconds: 300_000_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertFalse(files.contains { $0.contains(".partial-") }, "Orphaned staging output: \(files)")
    }

    private func waitUntilSettled(_ engine: WebProxyEngine, hash: String, rotation: Int) async throws -> WebProxyEngine.Status {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let state = await engine.status(forHash: hash, rotation: rotation)
            if state.ready || ["failed", "cancelled"].contains(state.state) { return state }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Proxy did not reach a terminal state")
        await engine.shutdown()
        throw CocoaError(.fileReadUnknown)
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var raw: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &raw) == kCVReturnSuccess,
              let buffer = raw else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 128, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
