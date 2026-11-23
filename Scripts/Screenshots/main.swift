// Hosts the compiled production views with disposable demo data.
// ScreenCaptureKit captures only the window owned by this process.
import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CryptoKit
import GRDB
@testable import Clipx

struct DemoShot: Decodable {
    var file: String
    var sourceName: String
    var name: String
    var inMs: Int64
    var outMs: Int64
    var rating: Int
    var tags: [String]
}

enum CaptureError: Error { case failed(String) }

@MainActor
func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = descendant(type, in: child) { return match }
    }
    return nil
}

@MainActor
func capture(_ window: NSWindow, name: String, output: URL) async throws -> [String: Any] {
    window.contentView?.layoutSubtreeIfNeeded()
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let owned = content.windows.first(where: {
        $0.windowID == UInt32(window.windowNumber) &&
        $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
    }) else { throw CaptureError.failed("Owned window unavailable") }
    let filter = SCContentFilter(desktopIndependentWindow: owned)
    guard abs(owned.frame.width - window.frame.width) < 1,
          abs(owned.frame.height - window.frame.height) < 1, owned.frame.width >= 900 else {
        throw CaptureError.failed("Window is transformed or minimized")
    }
    let config = SCStreamConfiguration()
    config.width = Int(owned.frame.width * window.backingScaleFactor)
    config.height = Int(owned.frame.height * window.backingScaleFactor)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let picture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let bitmap = NSBitmapImageRep(cgImage: picture)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CaptureError.failed("PNG encoding failed")
    }
    try png.write(to: output.appendingPathComponent(name + ".png"))
    print("Captured \(name): \(picture.width) × \(picture.height)")
    return ["file": name + ".png", "pixelWidth": picture.width, "pixelHeight": picture.height,
            "windowWidth": owned.frame.width, "windowHeight": owned.frame.height,
            "nativeToolbar": window.toolbar != nil, "windowID": owned.windowID]
}

@MainActor
func run() async throws {
    guard ProcessInfo.processInfo.environment["CLIPX_ISOLATED_TESTS"] == "1",
          let isolatedDirectory = AppPreferences.dataDirectory else {
        throw CaptureError.failed("An isolated library is required")
    }
    guard CGPreflightScreenCaptureAccess() else {
        throw CaptureError.failed("Existing Screen Recording permission is required; no prompt was requested")
    }
    guard CommandLine.arguments.count == 3 else {
        throw CaptureError.failed("Expected a footage manifest and output directory")
    }
    let manifest = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let shots = try JSONDecoder().decode([DemoShot].self, from: Data(contentsOf: manifest))
    guard !shots.isEmpty else { throw CaptureError.failed("No demo footage supplied") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    AppPreferences.defaults.set(true, forKey: "didCompleteOnboarding")
    AppPreferences.defaults.set(false, forKey: "webServerEnabled")
    AppPreferences.defaults.set(true, forKey: "openClipsInBuiltInPlayer")
    Purposes.activePresetID = "creator"
    let state = AppState.shared
    AppEnvironment.shared.bootstrap()
    for _ in 0..<250 where !state.bootstrapped && state.bootstrapError == nil {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard state.bootstrapped, let database = AppEnvironment.shared.database,
          let store = AppEnvironment.shared.markerStore,
          let engine = AppEnvironment.shared.thumbnailEngine else {
        throw CaptureError.failed(state.bootstrapError ?? "Bootstrap timed out")
    }
    defer { AppEnvironment.shared.shutdown() }
    let projectID = try database.write { db -> Int64 in
        try db.execute(sql: "INSERT INTO projects(name,status,created_at) VALUES('Coastal study','editing',1794787200)")
        return db.lastInsertedRowID
    }
    let collectionID = try database.write { db -> Int64 in
        try db.execute(sql: "INSERT INTO collections(name,created_at) VALUES('Opening selects',1794787200)")
        return db.lastInsertedRowID
    }
    let media = isolatedDirectory.appendingPathComponent("Coastal study", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    var clips: [Clip] = []
    var sources: [[String: Any]] = []
    for (index, shot) in shots.enumerated() {
        let original = URL(fileURLWithPath: shot.file, relativeTo: manifest.deletingLastPathComponent())
        let file = media.appendingPathComponent(shot.sourceName)
        try FileManager.default.copyItem(at: original, to: file)
        let meta = await MetadataExtractor.extract(url: file)
        guard let duration = meta.durationMs, duration >= shot.outMs,
              let width = meta.width, let height = meta.height else {
            throw CaptureError.failed("Invalid or incomplete media: \(shot.file)")
        }
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        var source = Source(path: file.path, hash: hash, mtime: 1794787200,
                            durationMs: duration, width: width, height: height, fps: meta.fps,
                            codec: meta.codec, audioChannels: meta.audioChannels, colorSpace: meta.colorSpace,
                            createdAt: 1794787200, importedAt: 1794787200)
        try database.write { try source.insert($0) }
        let clip = try store.saveRange(sourceID: source.id!, inMs: shot.inMs, outMs: shot.outMs,
                                       name: shot.name, rating: shot.rating, tags: shot.tags,
                                       purposes: index == 0 ? ["publish", "broll"] : ["broll"],
                                       projectIDs: [projectID], collectionIDs: index < 2 ? [collectionID] : [])
        clips.append(clip)
        let thumbnail: URL? = await withCheckedContinuation { continuation in
            engine.generateThumbnail(source: source) { continuation.resume(returning: $0) }
        }
        guard thumbnail != nil else { throw CaptureError.failed("Thumbnail failed: \(shot.file)") }
        if index == 0 {
            let sprite: URL? = await withCheckedContinuation { continuation in
                engine.generateSprite(source: source) { continuation.resume(returning: $0) }
            }
            guard sprite != nil else { throw CaptureError.failed("Filmstrip generation failed") }
        }
        sources.append(["file": shot.sourceName, "sha256": hash, "durationMs": duration,
                        "width": width, "height": height, "fps": meta.fps ?? 0])
    }
    let hero = clips[0]
    try store.updateNotes(hero.id!, notes: "Open on the headland, then cut to the surf.\nLet the waves settle before the transition.")
    try store.updateColorLabel(hero.id!, label: 4)
    try store.updateMood(hero.id!, mood: "Calm")
    _ = try store.saveRange(sourceID: hero.sourceID, inMs: 12500, outMs: 18000,
                           name: "Shoreline drift", rating: 4, tags: ["coast"], purposes: ["broll"])
    state.libraryRevision &+= 1
    state.viewMode = .grid
    state.sortOption = .nameAsc
    state.selectProject(projectID)
    let host = NSHostingController(rootView: RootView().environmentObject(state)
        .frame(minWidth: 900, minHeight: 700).preferredColorScheme(.dark).tint(Theme.accent))
    let window = NSWindow(contentViewController: host)
    window.isReleasedWhenClosed = false
    window.title = "Clipx"
    window.titleVisibility = .hidden
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.toolbarStyle = .unified
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(Theme.bg)
    window.setContentSize(NSSize(width: 1140, height: 720))
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await Task.sleep(nanoseconds: 2_000_000_000)
    var captures = [try await capture(window, name: "library", output: output)]
    state.openClip(hero)
    state.showInspector(.details)
    try await Task.sleep(nanoseconds: 2_000_000_000)
    guard let surface = descendant(PlayerSurfaceView.self, in: host.view),
          let layer = surface.playerLayer, let player = layer.player else {
        throw CaptureError.failed("Production AVPlayerLayer not mounted")
    }
    player.isMuted = true
    for _ in 0..<100 where player.currentItem?.status != .readyToPlay {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard player.currentItem?.status == .readyToPlay else {
        throw CaptureError.failed("Video did not become playable")
    }
    let seeked = await player.seek(to: CMTime(value: 6000, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    guard seeked else { throw CaptureError.failed("Video seek failed") }
    player.pause()
    for _ in 0..<100 where !layer.isReadyForDisplay {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard layer.isReadyForDisplay else { throw CaptureError.failed("Video frame unavailable") }
    try await Task.sleep(nanoseconds: 2_000_000_000)
    var workspace = try await capture(window, name: "workspace", output: output)
    workspace["playerTimeSeconds"] = player.currentTime().seconds
    workspace["videoReadyForDisplay"] = layer.isReadyForDisplay
    captures.append(workspace)
    let evidence: [String: Any] = ["captureMethod": "ScreenCaptureKit owned NSWindow, production RootView and AVPlayerLayer",
                                  "isolated": true, "sources": sources, "captures": captures]
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("capture.json"))
}

let app = NSApplication.shared
// Avoid activating Spaces or Stage Manager, including during a locked session.
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .darkAqua)
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("Capture failed: \(error)"); exit(1) }
}
app.run()
