import XCTest
import SwiftUI
import AppKit
import AVFoundation
import CoreVideo
import GRDB
@testable import Clipx

/// In-process rendering exercises the production views and services without
/// requiring XCUITest's machine-wide developer-mode permission. It captures
/// only windows created here and never reads the desktop or the real library.
final class NativeUIRenderTests: XCTestCase {
    @MainActor
    func test_isolatedNativeWindowsRenderLibraryPlayerAndOnboarding() async throws {
        guard let isolatedDirectory = AppPreferences.dataDirectory else {
            throw XCTSkip("Native rendering requires CLIPX_ISOLATED_TESTS=1 or CLIPX_DATA_DIRECTORY")
        }
        let evidence = URL(fileURLWithPath: "/tmp/clipx-native-ui-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        AppPreferences.defaults.set(true, forKey: "didCompleteOnboarding")
        AppPreferences.defaults.set(false, forKey: "webServerEnabled")
        AppPreferences.defaults.set(true, forKey: "openClipsInBuiltInPlayer")
        Purposes.activePresetID = "creator"
        let state = AppState.shared
        AppEnvironment.shared.bootstrap()
        for _ in 0..<250 where !state.bootstrapped && state.bootstrapError == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(state.bootstrapError)
        XCTAssertTrue(state.bootstrapped)
        let database = try XCTUnwrap(AppEnvironment.shared.database)
        let store = try XCTUnwrap(AppEnvironment.shared.markerStore)
        let footage = isolatedDirectory.appendingPathComponent("UI-Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: footage, withIntermediateDirectories: true)
        let movieURL = footage.appendingPathComponent("2026_08_25_Coastal_Walk.mov")
        try await makeMovie(at: movieURL)
        let sourceIDs = try database.write { db -> [Int64] in
            try db.execute(sql: "DELETE FROM sources")
            try db.execute(sql: "DELETE FROM projects")
            try db.execute(sql: "DELETE FROM collections")
            var ids: [Int64] = []
            for (index, name) in ["2026_08_25_Coastal_Walk.mov", "2026_08_25_Cliff_Detail.mov", "2026_08_24_Evening_Light.mov"].enumerated() {
                let url = footage.appendingPathComponent(name)
                if url != movieURL { try FileManager.default.copyItem(at: movieURL, to: url) }
                try db.execute(sql: """
                    INSERT INTO sources(path,hash,mtime,imported_at,created_at,duration_ms,width,height,fps,codec,online)
                    VALUES(?,?,0,1787659200,?,3000,640,360,30,'h264',1)
                    """, arguments: [url.path, "ui-\(index)", 1787659200 - index * 86400])
                ids.append(db.lastInsertedRowID)
            }
            try db.execute(sql: "INSERT INTO projects(name,status,created_at) VALUES('Coastal film','active',1787659200)")
            return ids
        }
        let projectID = try XCTUnwrap(database.read { try Int64.fetchOne($0, sql: "SELECT id FROM projects LIMIT 1") })
        let hero = try store.saveRange(sourceID: sourceIDs[0], inMs: 200, outMs: 1700,
                                      name: "Coast detail", rating: 4, tags: ["coast", "golden hour"],
                                      purposes: ["publish", "broll"], projectIDs: [projectID])
        try store.updateNotes(hero.id!, notes: "Hold on the water before the cut.\nUse the natural sound underneath the opening.")
        let second = try store.saveRange(sourceID: sourceIDs[1], inMs: 500, outMs: 2200,
                                        name: "Cliff reveal", rating: 5, tags: ["coast"], purposes: ["short"])
        for id in sourceIDs {
            if let source = try database.read({ try Source.fetchOne($0, key: id) }),
               let engine = AppEnvironment.shared.thumbnailEngine {
                let thumbnail: URL? = await withCheckedContinuation { continuation in
                    engine.generateThumbnail(source: source) { continuation.resume(returning: $0) }
                }
                XCTAssertNotNil(thumbnail)
            }
        }
        defer {
            state.playerSourceID = nil
            state.selectedClipIDs = []
            state.inspectorVisible = false
            state.searchQuery = ""
            state.clearFilters()
        }
        state.playerSourceID = nil
        state.selectedClipIDs = []
        state.inspectorVisible = false
        state.searchQuery = ""
        state.clearFilters()
        state.libraryRevision &+= 1
        state.viewMode = .calendar
        try await capture(RootView(), state: state, size: NSSize(width: 1320, height: 820), name: "01-calendar", in: evidence)
        state.viewMode = .grid
        try await capture(RootView(), state: state, size: NSSize(width: 1320, height: 820), name: "02-grid", in: evidence)
        state.viewMode = .list
        try await capture(RootView(), state: state, size: NSSize(width: 1320, height: 820), name: "03-list", in: evidence)
        state.viewMode = .lightTable
        state.selectedClipIDs = [hero.id!]
        state.inspectorVisible = true
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "04-light-table-inspector-narrow", in: evidence)
        state.viewMode = .calendar
        state.searchQuery = "golden hour"
        try await capture(RootView(), state: state, size: NSSize(width: 1320, height: 820), name: "05-filtered-clip-inspector", in: evidence)
        state.searchQuery = "nothing-matches-this-query"
        state.inspectorVisible = false
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "06-no-results", in: evidence)
        state.searchQuery = ""
        state.selectProject(projectID)
        state.inspectorVisible = true
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "07-project-narrow", in: evidence)
        state.clearFilters()
        state.selectedClipIDs = [hero.id!, second.id!]
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "08-multiple-selection", in: evidence)
        state.openClip(hero)
        state.inspectorVisible = false
        try await capture(RootView(), state: state, size: NSSize(width: 1320, height: 820), name: "09-player", in: evidence)
        state.inspectorVisible = true
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "10-player-inspector-narrow", in: evidence)
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "11-capture-narrow", in: evidence,
                          beforeCapture: { NotificationCenter.default.post(name: .saveRange, object: nil) })
        state.playerSourceID = nil
        state.inspectorVisible = false
        try await capture(OnboardingView(onComplete: {}), state: state, size: NSSize(width: 624, height: 544), name: "12-onboarding-welcome", in: evidence)
        try await capture(OnboardingView(initialStep: 3, onComplete: {}), state: state, size: NSSize(width: 624, height: 544), name: "13-onboarding-ready", in: evidence)
        try await capture(SettingsView(), state: state, size: NSSize(width: 680, height: 600), name: "14-settings", in: evidence)
        try await capture(RemoteSettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "15-remote-settings", in: evidence)
        try await capture(ExportSettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "16-export-settings", in: evidence)
        try await capture(SidebarView(), state: state, size: NSSize(width: 240, height: 700), name: "17-sidebar", in: evidence)
        try await capture(SessionRailView(currentSourceID: sourceIDs[0], onPick: { _ in }), state: state,
                          size: NSSize(width: 240, height: 700), name: "18-session-rail", in: evidence)
        try await capture(OnboardingView(initialStep: 1, onComplete: {}), state: state, size: NSSize(width: 624, height: 544), name: "19-onboarding-folder", in: evidence)
        try await capture(OnboardingView(initialStep: 2, onComplete: {}), state: state, size: NSSize(width: 624, height: 544), name: "20-onboarding-vault", in: evidence)
        try await capture(LabelsSettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "21-label-settings", in: evidence)
        try await capture(LibrarySettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "22-library-settings", in: evidence)
        try await capture(BridgesSettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "23-bridge-settings", in: evidence)
        try await capture(HotkeySettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "24-hotkey-settings", in: evidence)
        try await capture(UpdatesSettingsView(), state: state, size: NSSize(width: 680, height: 540), name: "25-update-settings", in: evidence)
        state.commandPaletteOpen = true
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "26-command-palette", in: evidence)
        state.commandPaletteOpen = false
        state.shortcutOverlayOpen = true
        try await capture(RootView(), state: state, size: NSSize(width: 900, height: 700), name: "27-shortcuts", in: evidence)
        state.shortcutOverlayOpen = false
        try await capture(PlayerView(sourceID: .max), state: state, size: NSSize(width: 900, height: 700), name: "28-missing-source", in: evidence)
        try await capture(ExportProgressView(), state: state, size: NSSize(width: 480, height: 320), name: "29-export-queue", in: evidence)
        print("CLIPX_NATIVE_UI_EVIDENCE=\(evidence.path)")
    }

    @MainActor
    private func capture<V: View>(_ view: V, state: AppState, size: NSSize, name: String, in directory: URL,
                                 beforeCapture: (() -> Void)? = nil) async throws {
        let host = NSHostingView(rootView: view.environmentObject(state).preferredColorScheme(.dark).tint(Theme.accent))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Clipx — Native UI Verification"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.044, blue: 0.055, alpha: 1)
        window.contentView = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 900_000_000)
        beforeCapture?()
        if beforeCapture != nil { try await Task.sleep(nanoseconds: 300_000_000) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertLessThanOrEqual(host.bounds.width, size.width + 1, "\(name) must respect the requested window width")
        XCTAssertLessThanOrEqual(window.contentLayoutRect.width, size.width + 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4000, "The \(name) window should contain visible native UI")
        let bitmapURL = directory.appendingPathComponent(name + "-bitmap.png")
        let imageURL = directory.appendingPathComponent(name + ".png")
        try data.write(to: bitmapURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), imageURL.path]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        var captureDescription = "AppKit bitmap fallback; system materials, window chrome, and AVPlayerLayer may be absent."
        do {
            try process.run()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: imageURL.path) {
                captureDescription = "Composited capture of this test-owned NSWindow only."
            } else {
                try data.write(to: imageURL)
                captureDescription += " Window capture failed: " + String(decoding: result, as: UTF8.self)
            }
        } catch {
            try data.write(to: imageURL)
            captureDescription += " Window capture unavailable: " + error.localizedDescription
        }
        let geometry = "Requested \(size.width) × \(size.height); hosted \(host.bounds.width) × \(host.bounds.height).\n" + captureDescription
        try geometry.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(data: try Data(contentsOf: imageURL), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeMovie(at url: URL) async throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * stride + x * 4
                let sky = y < 155
                let cliff = x < 140 && y > 120 + x / 3
                let wave = (y + x / 13) % 19 < 2
                bytes[index] = 255
                bytes[index + 1] = cliff ? 47 : sky ? UInt8(180 + y / 4) : wave ? 112 : 39
                bytes[index + 2] = cliff ? 51 : sky ? UInt8(189 + y / 4) : wave ? 159 : 111
                bytes[index + 3] = cliff ? 49 : sky ? 206 : wave ? 165 : 129
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
