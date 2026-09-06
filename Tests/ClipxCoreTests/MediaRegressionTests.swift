import XCTest
import AVFoundation
@testable import Clipx

final class MediaRegressionTests: XCTestCase {
    func testCancellationBeforeBackendRegistrationIsLatched() {
        let box = CancellerBox()
        let called = expectation(description: "late canceller")
        box.cancel()
        box.set { called.fulfill() }
        wait(for: [called], timeout: 1)
        XCTAssertTrue(box.isCancelled)
        XCTAssertThrowsError(try box.checkCancellation())
    }

    func testRenderRequestIncludesTransformsAndFrameEndpoints() throws {
        var source = Self.source(path: "/fixture.mp4")
        source.rotation = 90
        source.speed = 0.125
        let clip = Clip(id: 1, sourceID: 1, inMs: 33, outMs: 1000, createdAt: 0)
        let request = try ClipRenderRequest(clip: clip, source: source, preset: .reels,
                                            outputURL: URL(fileURLWithPath: "/tmp/render.mp4"))
        XCTAssertEqual(request.rotation, 90)
        XCTAssertEqual(request.speed, 0.125)
        XCTAssertEqual(request.inMs, 33)
        XCTAssertEqual(request.expectedDurationSeconds, 7.736, accuracy: 0.0001)
    }

    func testCancelledOrFailedRenderPreservesExistingDestination() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("existing.mp4")
        let existing = Data("Keep the user's file".utf8)
        try existing.write(to: output)
        let request = try ClipRenderRequest(
            clip: Clip(id: 1, sourceID: 1, inMs: 0, outMs: 1000, createdAt: 0),
            source: Self.source(path: folder.appendingPathComponent("missing.mp4").path),
            preset: Self.smallPreset, outputURL: output
        )
        for cancelled in [true, false] {
            let cancellation = CancellerBox()
            if cancelled { cancellation.cancel() }
            do {
                _ = try await ClipRenderer.render(request, cancellation: cancellation)
                XCTFail("Expected cancellation or missing-source failure")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: output), existing)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["existing.mp4"])
        }
    }

    func testStagedOutputCannotReplaceDestinationCreatedDuringRender() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let finalURL = folder.appendingPathComponent("existing.mp4")
        let output = try StagedRenderOutput(destination: finalURL)
        try Data("rendered output".utf8).write(to: output.url)
        let otherFile = Data("created by another writer".utf8)
        try otherFile.write(to: finalURL)
        XCTAssertThrowsError(try output.publish())
        output.cleanup()
        XCTAssertEqual(try Data(contentsOf: finalURL), otherFile)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["existing.mp4"])
    }

    #if DIRECT_BUILD
    func testFFmpegCutsSourceBeforeRetimeAndPreservesBoundaryFrames() async throws {
        try Self.requireFFmpeg()
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("bands.mp4")
        try Self.makeColorFixture(at: source)
        for speed in [0.5, 1, 2] {
            let output = folder.appendingPathComponent("speed-\(speed).mp4")
            let arguments = FFmpegBackend.buildArguments(sourcePath: source.path, inMs: 2000, outMs: 6000,
                                                        preset: Self.smallPreset, outputPath: output.path, speed: speed)
            let status = try await FFmpegBackend.run(arguments: arguments, durationSec: 4 / speed)
            XCTAssertEqual(status, 0)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 4 / speed, accuracy: 0.04, "speed \(speed)")
            let first = try Self.pixel(asset: asset, seconds: 0)
            let last = try Self.pixel(asset: asset, seconds: duration - 0.15)
            XCTAssertGreaterThan(first[1], 200, "In must start in the green segment")
            XCTAssertLessThan(first[0], 30)
            XCTAssertLessThan(first[2], 30)
            XCTAssertGreaterThan(last[2], 200, "Out must end in the blue segment")
            XCTAssertLessThan(last[0], 30)
            XCTAssertLessThan(last[1], 30)
        }
    }

    func testFFmpegCancelledBeforeLaunchDoesNotCreateOutput() async throws {
        try Self.requireFFmpeg()
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("cancelled.mp4")
        let cancellation = CancellerBox()
        cancellation.cancel()
        do {
            _ = try await FFmpegBackend.run(arguments: ["-f", "lavfi", "-i", "color=red:d=1", "-y", output.path],
                                            onCancellerRegistered: { cancellation.set($0) })
            XCTFail("A cancelled process must not launch")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testHDRRenderConvertsToSDRBeforeFinalEncoding() async throws {
        try Self.requireFFmpeg()
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("hlg.mp4")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: FFmpegBackend.ffmpegPath)
        generator.arguments = [
            "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2",
            "-vf", "setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc",
            "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
            "-x265-params", "pools=1:log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc", sourceURL.path
        ]
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        try XCTSkipUnless(generator.terminationStatus == 0, "HDR fixture generation requires the optional libx265 encoder")
        let needsConversion = try await ClipRenderer.requiresSDRConversion(sourcePath: sourceURL.path)
        XCTAssertTrue(needsConversion)
        var source = Self.source(path: sourceURL.path)
        source.durationMs = 2000
        let clip = Clip(id: 1, sourceID: 1, inMs: 500, outMs: 1500, createdAt: 0)
        let output = folder.appendingPathComponent("converted.mp4")
        let request = try ClipRenderRequest(clip: clip, source: source, preset: Self.smallPreset, outputURL: output)
        let result = try await ClipRenderer.render(request)
        XCTAssertLessThanOrEqual(abs(result.durationMs - 1000), 35)
        let stillNeedsConversion = try await ClipRenderer.requiresSDRConversion(sourcePath: output.path)
        XCTAssertFalse(stillNeedsConversion)
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first
        let description = try await XCTUnwrap(track).load(.formatDescriptions).first
        let format = try XCTUnwrap(description)
        XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                       AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                       AVVideoTransferFunction_ITU_R_709_2)
    }

    func testAVFoundationCancellationCannotRecreatePartialOutput() async throws {
        try Self.requireFFmpeg()
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("bands.mp4")
        try Self.makeColorFixture(at: source)
        let output = folder.appendingPathComponent("cancelled.mp4")
        let cancellation = CancellerBox()
        let exporting = Task {
            try await AVFoundationBackend.export(
                sourcePath: source.path, inMs: 0, outMs: 8000, preset: .youtube4k,
                outputPath: output.path, onCancellerRegistered: { cancellation.set($0) }, onProgress: { _ in }
            )
        }
        // Cancel during metadata/session preparation, the window in which a
        // delayed AVFoundation writer previously recreated an unlinked output.
        try await Task.sleep(nanoseconds: 10_000_000)
        cancellation.cancel()
        exporting.cancel()
        do { try await exporting.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["bands.mp4"])
    }

    static func requireFFmpeg() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: FFmpegBackend.ffmpegPath), "FFmpeg fixture generator is unavailable")
    }

    static func makeColorFixture(at url: URL) throws {
        let bands = "color=black:s=160x90:r=30:d=8,drawbox=color=red:t=fill:enable='lt(t,2)',drawbox=color=lime:t=fill:enable='gte(t,2)*lt(t,4)',drawbox=color=blue:t=fill:enable='gte(t,4)*lt(t,6)',drawbox=color=yellow:t=fill:enable='gte(t,6)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpegBackend.ffmpegPath)
        process.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", bands,
                             "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-c:v", "libx264",
                             "-pix_fmt", "yuv420p", "-c:a", "aac", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif

    static var smallPreset: ExportPreset {
        ExportPreset(id: "test", displayName: "Test", width: 160, height: 90, frameRate: 30,
                     videoBitrateKbps: 250, audioBitrateKbps: 64, codec: .h264,
                     lufsTarget: nil, colorPrimaries: .bt709, containerExt: "mp4", requiresFFmpeg: false)
    }

    static func source(path: String) -> Source {
        Source(id: 1, path: path, hash: "fixture", mtime: 0, durationMs: 8000,
               width: 160, height: 90, fps: 30, audioChannels: 1, importedAt: 0)
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipx-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func pixel(asset: AVAsset, seconds: Double) throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
