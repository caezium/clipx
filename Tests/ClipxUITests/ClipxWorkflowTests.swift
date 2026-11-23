import XCTest

/// Drives an isolated application bundle through its actual native UI.
final class ClipxWorkflowTests: XCTestCase {
    @MainActor
    func testImportMarkSaveAndInspect() throws {
        continueAfterFailure = false
        let evidence = URL(fileURLWithPath: "/tmp/clipx-ui-evidence", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let footage = evidence.appendingPathComponent("Footage", isDirectory: true)
        let data = evidence.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: footage, withIntermediateDirectories: true)
        try evidence.path.write(to: URL(fileURLWithPath: "/tmp/clipx-ui-evidence-latest"), atomically: true, encoding: .utf8)
        let source = footage.appendingPathComponent("2026_08_25_Coastal_Walk.mov")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try run(products.appendingPathComponent("Clipx.app/Contents/Helpers/ffmpeg"), ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
            "-t", "8", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: source.path)

        let app = XCUIApplication(bundleIdentifier: "com.clipx.Clipx.Verification")
        app.launchEnvironment["CLIPX_DATA_DIRECTORY"] = data.path
        app.launch()
        addTeardownBlock { @MainActor in
            try? app.debugDescription.write(to: evidence.appendingPathComponent("final-accessibility.txt"), atomically: true, encoding: .utf8)
            app.terminate()
        }
        func capture(_ name: String) throws {
            let screenshot = app.windows.firstMatch.screenshot()
            try screenshot.pngRepresentation.write(to: evidence.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            try app.debugDescription.write(to: evidence.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 20))
        try capture("01-onboarding")
        app.buttons["Get Started"].click()
        app.buttons["Pick Folder…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(footage.path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Choose"].waitForExistence(timeout: 5))
        app.buttons["Choose"].click()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 10))
        app.buttons["Skip"].click()
        try capture("01b-onboarding-ready")
        app.buttons["Open a video & start clipping"].click()
        let card = app.descendants(matching: .any).matching(identifier: source.lastPathComponent).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        try capture("02-library")
        card.doubleClick()
        XCTAssertTrue(app.buttons["player.markIn"].waitForExistence(timeout: 10))
        try capture("03-player")
        app.buttons["player.markIn"].click()
        for _ in 0..<15 { app.buttons["player.nextFrame"].click() }
        app.buttons["player.markOut"].click()
        app.buttons["player.saveRange"].click()
        let name = app.textFields["Name this clip…"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Coast detail")
        try capture("04-capture")
        app.buttons["capture.save"].click()
        XCTAssertTrue(app.staticTexts["Coast detail"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["library.inspector"].click()
        let inspectorName = app.textFields["inspector.name"]
        XCTAssertTrue(inspectorName.waitForExistence(timeout: 5))
        inspectorName.click()
        inspectorName.typeKey("a", modifierFlags: .command)
        inspectorName.typeText("Coast detail edited")
        // Switching tasks must flush a pending name and retain the notes draft.
        app.buttons["inspector.tab.notes"].click()
        let notes = app.textViews["inspector.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.click()
        notes.typeText("Hold this moment before the cut.")
        app.buttons["inspector.tab.export"].click()
        XCTAssertTrue(app.buttons["inspector.exportVideo"].waitForExistence(timeout: 5))
        try capture("05-export-panel")
        app.buttons["inspector.tab.notes"].click()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertEqual(notes.value as? String, "Hold this moment before the cut.")
        try capture("06-notes-panel")
        // Navigating away must commit without Return.
        app.buttons["Library"].click()
        try capture("07-library")
        let saved = try run(URL(fileURLWithPath: "/usr/bin/sqlite3"), [data.appendingPathComponent("clipx.sqlite").path,
            "SELECT name || '|' || notes || '|' || (out_ms > in_ms AND in_ms >= 0) FROM clips;"])
        XCTAssertTrue(saved.contains("Coast detail edited|Hold this moment before the cut.|1"), saved)
        try saved.write(to: evidence.appendingPathComponent("persisted-clip.txt"), atomically: true, encoding: .utf8)
        print("CLIPX_UI_EVIDENCE=\(evidence.path)")
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }
}
