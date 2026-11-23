import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Built-in player with frame-accurate scrubbing and I/O marking hotkeys.
struct PlayerView: View {
    let sourceID: Int64
    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = PlayerController()
    @State private var source: Source?
    @State private var sourceError: String?
    @State private var savedClips: [Clip] = []
    @State private var savedClipsTask: Task<Void, Never>?
    @State private var savedClipsGeneration = UUID()
    @FocusState private var keyboardFocused: Bool
    // Tag-at-the-cut: pressing Save opens an inline capture instead of writing a
    // nameless clip and forcing a trip to the Inspector.
    @State private var capturing = false
    @State private var captureSuggestions: [String] = []
    // Hold-Space → temporary 2× (vs a tap, which toggles play/pause).
    @State private var spaceHoldTask: Task<Void, Never>?
    @State private var spaceHoldEngaged = false
    // Custom playback-speed entry (the speed menu's "Custom…" item).
    @State private var showCustomSpeed = false
    @State private var customSpeedText = ""
    @State private var showPlaybackOptions = false
    /// Skip step for the double-tap-a-side gesture.
    private let doubleTapSkipSeconds: Double = 10

    var body: some View {
        VStack(spacing: 0) {
            // The PlayerSurface (AVPlayerLayer) does its own aspect-correct
            // letterboxing via videoGravity = .resizeAspect, so we don't ask
            // SwiftUI to enforce a ratio — that was forcing the detail column
            // to demand a huge minimum width and crushing the sidebar.
            ZStack {
                Color.black
                if let player = controller.player {
                    PlayerSurface(player: player)
                        .contentShape(Rectangle())
                }
                if let error = sourceError ?? controller.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash").font(.title)
                        Text("Couldn't open this video").font(.headline)
                        Text(error).font(.callout).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        HStack {
                            Button("Try Again", action: load)
                            Button("Back to Library", action: exitToLibrary)
                        }
                    }
                    .padding(24).frame(maxWidth: 400)
                } else if controller.isLoading {
                    ProgressView("Opening video…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(-1)
            .clipShape(RoundedRectangle(cornerRadius: Theme.r3))
            // Tap to focus, double-tap a side to skip ±, press-and-hold for 2×.
            // Hidden while the capture card is up so it gets the events.
            .overlay { if !capturing && playbackReady { videoGestureZones } }
            // The capture card floats over the bottom of the video so marking
            // → naming → tagging never leaves the player.
            .overlay(alignment: .bottom) {
                if capturing {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                captureCard
                            }
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Skimmable filmstrip timeline: the source's sampled frames drawn
            // across the width so a long source is visually scannable, with the
            // in/out band, saved-clip pins, and playhead over it.
            FilmstripTimelineView(
                controller: controller,
                totalMs: controller.durationMs,
                sourceHash: source?.hash,
                sourceURL: source?.url,
                savedClips: savedClips,
                onSelectClip: { clip in
                    if let id = clip.id { appState.selectedClipIDs = [id] }
                    appState.playerInMs = clip.inMs
                    appState.playerOutMs = clip.outMs
                    controller.seek(toMs: clip.inMs)
                }
            )
            .frame(height: 68)
            controlBar
            if !savedClips.isEmpty {
                savedClipsStrip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        // .task(id:) waits for the view to be in the hierarchy before running;
        // setting focus inside this closure is reliable even if a sheet is
        // racing the same runloop. Re-runs whenever sourceID changes.
        .task(id: sourceID) {
            load()
            reloadSavedClips()
            keyboardFocused = true
        }
        .onChange(of: appState.libraryRevision) { _, _ in reloadSavedClips() }
        .onChange(of: appState.playerOpenRevision) { _, _ in
            if appState.playerSourceID == sourceID, let inMs = appState.playerInMs {
                controller.seek(toMs: inMs)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemWillSleep)) { _ in
            controller.pause()
        }
        .onDisappear {
            spaceHoldTask?.cancel()
            savedClipsTask?.cancel()
            savedClipsGeneration = UUID()
            controller.tearDown()
        }
        // All player hotkeys route through `key()`, which returns `.ignored`
        // while a text field is being edited (the capture card's name/tag
        // fields, etc.) so typing "s" doesn't fire Save. (onKeyPress on this
        // container otherwise also receives keys aimed at focused descendants.)
        .onKeyPress("i") { key { markIn() } }
        .onKeyPress("o") { key { markOut() } }
        .onKeyPress("s") { key { saveRange() } }
        // Space: tap = play/pause; press-and-hold = 2× while held (released
        // within ~0.2s counts as a tap). Ignored while editing text.
        .onKeyPress(.space, phases: [.down, .up]) { press in
            guard !capturing, !PlayerView.isEditingText() else { return .ignored }
            switch press.phase {
            case .down:
                spaceHoldEngaged = false
                spaceHoldTask?.cancel()
                spaceHoldTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    spaceHoldEngaged = true
                    controller.beginHoldSpeed()
                }
            case .up:
                spaceHoldTask?.cancel()
                if spaceHoldEngaged { controller.endHoldSpeed(); spaceHoldEngaged = false }
                else { controller.togglePlayPause() }
            default:
                break
            }
            return .handled
        }
        // Plain arrows: frame-accurate single-frame step.
        // Shift+arrow: 5-second jump for fast scrubbing.
        // J / L (industry-standard transport keys): also 5s jump.
        .onKeyPress(keys: [.leftArrow]) { press in
            key {
                if press.modifiers.contains(.shift) { controller.jumpBackward(seconds: 5) }
                else { controller.stepBackward() }
            }
        }
        .onKeyPress(keys: [.rightArrow]) { press in
            key {
                if press.modifiers.contains(.shift) { controller.jumpForward(seconds: 5) }
                else { controller.stepForward() }
            }
        }
        .onKeyPress("j") { key { controller.jumpBackward(seconds: 5) } }
        .onKeyPress("l") { key { controller.jumpForward(seconds: 5) } }
        .onKeyPress("k") { key { controller.togglePlayPause() } }
        // Esc leaves the Cut Room — but `key {}` returns .ignored while the
        // capture card is up, so its Cancel (.cancelAction) keeps Esc instead.
        .onKeyPress(.escape) { key { exitToLibrary() } }
        // Menu commands and command palette post these notifications. We observe
        // them here so the menu drives whichever player is currently visible.
        .onReceive(NotificationCenter.default.publisher(for: .markIn)) { _ in markIn() }
        .onReceive(NotificationCenter.default.publisher(for: .markOut)) { _ in markOut() }
        .onReceive(NotificationCenter.default.publisher(for: .saveRange)) { _ in saveRange() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepBack)) { _ in controller.stepBackward() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepForward)) { _ in controller.stepForward() }
    }

    private var playbackReady: Bool {
        sourceError == nil && controller.loadError == nil && !controller.isLoading && controller.durationMs > 0
    }

    private var hasValidRange: Bool {
        guard let start = appState.playerInMs, let end = appState.playerOutMs else { return false }
        return start >= 0 && end > start && end <= controller.durationMs
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transportControls
                    playbackTime
                    Spacer(minLength: 0)
                    playbackOptions
                }
                HStack(spacing: 8) {
                    transportControls
                    Spacer(minLength: 0)
                    ViewThatFits(in: .horizontal) {
                        playbackTime
                        PlaybackTimeLabel(clock: controller.clock)
                    }
                    compactPlaybackOptions
                }
            }
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    if appState.playerInMs != nil { rangeSummary }
                    Text(markingPrompt)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                    // Keep every marking button reachable at the minimum width.
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer(minLength: 0)
                markControls
            }
        }
        .disabled(!playbackReady || capturing)
        .padding(.horizontal, 4).padding(.vertical, 12)
    }

    private var markingPrompt: String {
        if hasValidRange { return "Ready to save" }
        if appState.playerInMs == nil { return "Mark In to start a clip" }
        return "Mark Out after In"
    }

    private var compactPlaybackOptions: some View {
        Button { showPlaybackOptions.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 14))
        }
        .buttonStyle(.plain).clipxIconButton(active: showPlaybackOptions)
        .accessibilityLabel("Playback options")
        .help("Volume, speed, and rotation")
        .popover(isPresented: $showPlaybackOptions) {
            playbackOptions.padding(16)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 2) {
            Button { controller.jumpBackward(seconds: 5) } label: {
                Image(systemName: "gobackward.5").font(.system(size: 15))
            }
            .buttonStyle(.plain).clipxIconButton()
            .help("Back 5s (J or ⇧←)").accessibilityLabel("Back five seconds")
            Button { controller.stepBackward() } label: {
                Image(systemName: "backward.frame.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain).clipxIconButton()
            .help("Previous frame (←)").accessibilityLabel("Previous frame")
            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain).clipxIconButton(size: 36)
            .help("Play / Pause (Space or K)")
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            Button { controller.stepForward() } label: {
                Image(systemName: "forward.frame.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain).clipxIconButton()
            .help("Next frame (→)")
            .accessibilityIdentifier("player.nextFrame").accessibilityLabel("Next frame")
            Button { controller.jumpForward(seconds: 5) } label: {
                Image(systemName: "goforward.5").font(.system(size: 15))
            }
            .buttonStyle(.plain).clipxIconButton()
            .help("Forward 5s (L or ⇧→)").accessibilityLabel("Forward five seconds")
        }
        .fixedSize()
    }

    private var playbackTime: some View {
        HStack(spacing: 4) {
            PlaybackTimeLabel(clock: controller.clock)
            Text("/").foregroundStyle(Theme.textTertiary)
            Text(controller.durationLabel)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
        .fixedSize()
        .padding(.horizontal, 4).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rangeSummary: some View {
        if let start = appState.playerInMs {
            HStack(spacing: 4) {
                Image(systemName: "scissors").font(.caption2)
                Text(PlayerController.formatMs(start))
                if let end = appState.playerOutMs {
                    Text("→ " + PlayerController.formatMs(end))
                    Text("(" + PlayerController.formatMs(FrameMath.rangeDuration(inMs: start, outMs: end)) + ")")
                        .opacity(0.8)
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Theme.success.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.success).fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    private var playbackOptions: some View {
        HStack(spacing: 10) {
            volumeControl
            speedMenu
            Button { rotate() } label: {
                Image(systemName: "rotate.right").font(.system(size: 14))
            }
            .buttonStyle(.plain).clipxIconButton(active: controller.rotation != 0)
            .help(controller.rotation == 0 ? "Rotate 90°" : "Rotated \(controller.rotation)° — click to rotate")
            .accessibilityLabel("Rotate video 90 degrees")
        }
        .fixedSize()
    }

    private var markControls: some View {
        HStack(spacing: 6) {
            Button(action: markIn) { Label("In", systemImage: "i.square") }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .help("Mark In (I)")
                .accessibilityIdentifier("player.markIn").accessibilityLabel("Mark In")
            Button(action: markOut) { Label("Out", systemImage: "o.square") }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .help("Mark Out (O)")
                .accessibilityIdentifier("player.markOut").accessibilityLabel("Mark Out")
            Button(action: saveRange) { Label("Save Clip", systemImage: "checkmark") }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(!hasValidRange)
                .help(hasValidRange ? "Save range as clip (S)" : "Mark In and Out to save a clip")
                .accessibilityIdentifier("player.saveRange").accessibilityLabel("Save Clip")
        }
        .fixedSize()
    }

    private func load() {
        guard let database = AppEnvironment.shared.database else { return }
        sourceError = nil
        do {
            guard let src: Source = try database.read({
                try Source.fetchOne($0, key: sourceID)
            }) else {
                controller.tearDown()
                sourceError = "This source is no longer in the library."
                return
            }
            self.source = src
            controller.load(url: src.url)
            controller.setRotation(src.rotation)   // restore the source's rotation
            controller.setSpeed(src.speed)         // restore the source's permanent speed
            if let inMs = appState.playerInMs {
                controller.seek(toMs: inMs)
            }
        } catch {
            controller.tearDown()
            sourceError = error.localizedDescription
            ClipxLog.player.error("PlayerView.load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs `action` and consumes the key — unless a text field is being edited
    /// (the capture card's name/tag fields, etc.), in which case the key is
    /// ignored so it reaches the field instead of firing a player shortcut.
    private func key(_ action: () -> Void) -> KeyPress.Result {
        if capturing || !playbackReady || PlayerView.isEditingText() { return .ignored }
        action()
        return .handled
    }

    /// True when a text field/editor currently holds keyboard focus. A focused
    /// SwiftUI TextField/TextEditor makes the field editor (an NSText subclass)
    /// the window's first responder.
    private static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText
    }

    /// Rotate the source 90° CW, persist it, and re-apply to the preview.
    private func rotate() {
        let newRotation = (controller.rotation + 90) % 360
        guard var src = source, let id = src.id, let database = AppEnvironment.shared.database else { return }
        do {
            try database.write { db in
                try db.execute(sql: "UPDATE sources SET rotation = ? WHERE id = ?", arguments: [newRotation, id])
            }
            controller.setRotation(newRotation)
            src.rotation = newRotation
            source = src
            AppState.shared.libraryRevision &+= 1
        } catch {
            appState.showToast("Couldn't save rotation: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Speed & volume controls

    private static let speedChoices: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0]

    private func speedLabel(_ s: Double) -> String { String(format: "%g×", s) }

    /// Set the permanent per-source speed, persist it, and apply to the preview.
    /// Mirrors `rotate()`; baked into exports via `Source.speed`.
    private func setSpeed(_ newSpeed: Double) {
        guard newSpeed.isFinite, var src = source, let id = src.id,
              let database = AppEnvironment.shared.database else { return }
        let speed = max(0.1, min(PlayerController.maxSpeed, newSpeed))
        do {
            try database.write { db in
                try db.execute(sql: "UPDATE sources SET speed = ? WHERE id = ?", arguments: [speed, id])
            }
            controller.setSpeed(speed)
            src.speed = speed
            source = src
            AppState.shared.libraryRevision &+= 1
        } catch {
            appState.showToast("Couldn't save speed: \(error.localizedDescription)", level: .error)
        }
    }

    /// True when the current speed isn't one of the presets (a custom value).
    private var speedIsCustom: Bool {
        !Self.speedChoices.contains { abs(controller.speed - $0) < 0.001 }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speedChoices, id: \.self) { s in
                Button {
                    setSpeed(s)
                } label: {
                    if abs(controller.speed - s) < 0.001 {
                        Label(speedLabel(s), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(s))
                    }
                }
            }
            Divider()
            Button {
                customSpeedText = String(format: "%g", controller.speed)
                showCustomSpeed = true
            } label: {
                // A checkmark when the active speed is a custom (non-preset) value.
                if speedIsCustom {
                    Label("Custom: \(speedLabel(controller.speed))", systemImage: "checkmark")
                } else {
                    Text("Custom…")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "speedometer").font(.system(size: 12))
                Text(speedLabel(controller.speed)).font(.system(size: 12).monospacedDigit())
            }
            .foregroundStyle(controller.speed == 1.0 ? Theme.textSecondary : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed — also baked into exports (e.g. 4× for slow-mo footage)")
        .alert("Custom speed", isPresented: $showCustomSpeed) {
            TextField("e.g. 3 or 0.75", text: $customSpeedText)
                .onSubmit(applyCustomSpeed)
            Button("Set", action: applyCustomSpeed)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Multiplier between \(speedLabel(0.1)) and \(speedLabel(PlayerController.maxSpeed)). Baked into exports.")
        }
    }

    /// Parse the typed multiplier (tolerating a trailing "x"/"×") and apply it.
    private func applyCustomSpeed() {
        let cleaned = customSpeedText
            .replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "x", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite,
              (0.1...PlayerController.maxSpeed).contains(value) else {
            appState.showToast("Enter a speed from 0.1× to \(speedLabel(PlayerController.maxSpeed)).", level: .warning)
            return
        }
        setSpeed(value)
    }

    private var volumeIcon: String {
        if controller.muted || controller.volume <= 0.001 { return "speaker.slash.fill" }
        if controller.volume < 0.5 { return "speaker.wave.1.fill" }
        if controller.volume > 1.0 { return "speaker.wave.3.fill" }   // boosted above source
        return "speaker.wave.2.fill"
    }

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Button { controller.toggleMute() } label: {
                Image(systemName: volumeIcon).font(.system(size: 13)).frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.muted ? Theme.accent : Theme.textSecondary)
            .help(controller.muted ? "Unmute" : "Mute")
            .accessibilityLabel(controller.muted ? "Unmute" : "Mute")
            Slider(
                value: Binding(
                    get: { controller.muted ? 0 : controller.volume },
                    set: { controller.setVolume($0) }
                ),
                in: 0...PlayerController.maxVolume
            )
            .controlSize(.mini)
            .frame(width: 64)
            .help("Volume — above the midpoint boosts gain above the source")
            .accessibilityLabel("Playback volume")
        }
    }

    // MARK: - Video gestures (tap focus / double-tap skip / hold 2×)

    private var videoGestureZones: some View {
        HStack(spacing: 0) {
            gestureZone(forward: false)
            gestureZone(forward: true)
        }
    }

    private func gestureZone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            // Double-tap a side to skip ±; single tap plays/pauses (and focuses
            // for hotkeys). The single tap resolves after the double-tap window.
            .onTapGesture(count: 2) {
                if forward { controller.jumpForward(seconds: doubleTapSkipSeconds) }
                else { controller.jumpBackward(seconds: doubleTapSkipSeconds) }
            }
            .onTapGesture {
                keyboardFocused = true
                controller.togglePlayPause()
            }
            // Press-and-hold anywhere on the video for temporary 2×.
            .simultaneousGesture(holdSpeedGesture)
    }

    private var holdSpeedGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second = value { controller.beginHoldSpeed() }  // idempotent
            }
            .onEnded { _ in controller.endHoldSpeed() }
    }

    private func markIn() {
        guard playbackReady, !capturing else { return }
        // Snap to the displayed frame so the mark matches what the user saw. (#14)
        appState.playerInMs = controller.currentFrameMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    private func markOut() {
        guard playbackReady, !capturing else { return }
        appState.playerOutMs = controller.currentFrameMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    /// Save (S) no longer writes a nameless clip — it opens the inline capture
    /// so the clip is named, tagged, and rated at the moment of the cut.
    private func saveRange() {
        guard !capturing, playbackReady else { return }
        guard let inMs = appState.playerInMs, let outMs = appState.playerOutMs, outMs > inMs else {
            AppState.shared.showToast("Mark in and out points first (I, O)", level: .warning)
            return
        }
        guard AppEnvironment.shared.markerStore != nil else {
            AppState.shared.showToast("Library still loading", level: .warning)
            return
        }
        // Pull existing tags so the user can one-tap the labels they already use.
        captureSuggestions = (try? AppEnvironment.shared.tagStore?
            .suggestions(prefix: "", limit: 14).map(\.name)) ?? []
        controller.pause()
        withAnimation(.easeOut(duration: 0.16)) { capturing = true }
    }

    /// Persist the captured clip with its name / rating / tags, then park the
    /// playhead past the out point and ready the next cut.
    private func commitCapture(name: String, rating: Int, tags: [String], purposes: [String]) {
        guard let inMs = appState.playerInMs, let outMs = appState.playerOutMs,
              let markerStore = AppEnvironment.shared.markerStore else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let clip = try markerStore.saveRange(
                sourceID: sourceID, inMs: inMs, outMs: outMs,
                name: trimmedName.isEmpty ? nil : trimmedName,
                rating: rating, tags: tags, purposes: purposes,
                projectIDs: appState.selectedProjectID.map { [$0] } ?? [],
                collectionIDs: appState.selectedCollectionID.map { [$0] } ?? []
            )
            if let id = clip.id { appState.selectedClipIDs = [id] }
            let count = savedClips.count + 1
            AppState.shared.showToast(
                trimmedName.isEmpty
                    ? "Saved clip \(count) (\(PlayerController.formatMs(FrameMath.rangeDuration(inMs: inMs, outMs: outMs))))"
                    : "Saved “\(trimmedName)” (\(PlayerController.formatMs(FrameMath.rangeDuration(inMs: inMs, outMs: outMs))))",
                level: .success
            )
            // Park just past the out point so the next clip can be marked without
            // re-scrubbing. Reload of the strip happens via libraryRevision.
            controller.seek(toMs: outMs)
            appState.playerInMs = nil
            appState.playerOutMs = nil
        } catch {
            AppState.shared.showToast("Failed to save: \(error.localizedDescription)", level: .error)
            return
        }
        withAnimation(.easeOut(duration: 0.16)) { capturing = false }
        keyboardFocused = true
    }

    private func cancelCapture() {
        // Keep the in/out marks so the user can re-scrub and try again.
        withAnimation(.easeOut(duration: 0.16)) { capturing = false }
        keyboardFocused = true
    }

    /// Leave the Cut Room and return to the library, clearing the pending
    /// in/out range. Bound to Esc via `onKeyPress` (only when not capturing).
    private func exitToLibrary() {
        appState.playerSourceID = nil
        appState.playerInMs = nil
        appState.playerOutMs = nil
    }

    private var captureCard: some View {
        ClipCaptureCard(
            durationMs: FrameMath.rangeDuration(inMs: appState.playerInMs ?? 0, outMs: appState.playerOutMs ?? 0),
            suggestions: captureSuggestions,
            onCommit: { name, rating, tags, purposes in
                commitCapture(name: name, rating: rating, tags: tags, purposes: purposes)
            },
            onCancel: { cancelCapture() }
        )
        // Fresh state each time a new range is captured.
        .id("\(appState.playerInMs ?? 0)-\(appState.playerOutMs ?? 0)")
    }

    private func reloadSavedClips() {
        savedClipsTask?.cancel()
        let generation = UUID()
        savedClipsGeneration = generation
        guard let store = AppEnvironment.shared.markerStore else { return }
        savedClipsTask = Task { @MainActor in
            let clips = await Task.detached(priority: .userInitiated) { [sourceID] in
                (try? store.fetchClips(forSource: sourceID)) ?? []
            }.value
            guard !Task.isCancelled, savedClipsGeneration == generation else { return }
            self.savedClips = clips
        }
    }

    /// Horizontal scrolling strip listing every clip already saved from this
    /// source. Click → load its range; double-click → also start playback.
    private var savedClipsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Clips from this source").clipxSectionLabel()
                Text("\(savedClips.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    AppState.shared.showToast(
                        "I = mark in · O = mark out · S = save · J/L = ±5s",
                        level: .info
                    )
                } label: {
                    Image(systemName: "info.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Keyboard shortcuts")
            }
            .padding(.horizontal, 14)
            .padding(.top, 7)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedClips, id: \.id) { clip in
                        savedClipChip(clip)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .padding(.top, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.r3))
    }

    private func savedClipChip(_ clip: Clip) -> some View {
        // Don't use -1 as a sentinel — if a row ever has id=-1 it collides.
        // Optional-map gives a clean "no id → not selected" answer.
        let isSelected: Bool = {
            if let id = clip.id { return appState.selectedClipIDs.contains(id) }
            return false
        }()
        return Button {
            if let id = clip.id { appState.selectedClipIDs = [id] }
            appState.playerInMs = clip.inMs
            appState.playerOutMs = clip.outMs
            controller.seek(toMs: clip.inMs)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scissors")
                    .font(.caption2)
                    .foregroundStyle(Theme.success)
                Text(clip.name ?? "Clip \(clip.id ?? 0)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(PlayerController.formatMs(clip.durationMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.r1)
                    .fill(isSelected ? Theme.accentSoft : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.r1)
                    .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Inspector") {
                if let id = clip.id {
                    appState.selectedClipIDs = [id]
                    appState.showInspector(.details)
                }
            }
            Divider()
            Button("Export as Reels") {
                if let id = clip.id { exportClip(id, preset: .reels) }
            }
            Button("Export as YouTube 1080p") {
                if let id = clip.id { exportClip(id, preset: .youtube1080p) }
            }
            Divider()
            Button("Delete clip", role: .destructive) {
                if let id = clip.id { deleteClip(id) }
            }
        }
    }

    private func exportClip(_ clipID: Int64, preset: ExportPreset) {
        ExportActions.export(clipIDs: [clipID], preset: preset)
    }

    private func deleteClip(_ clipID: Int64) {
        MarkerActions.deleteClips([clipID])
    }
}

/// Wraps AVPlayerLayer in an NSViewRepresentable so SwiftUI can host it.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerSurfaceView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.playerLayer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = (nsView as? PlayerSurfaceView)?.playerLayer {
            layer.player = player
        }
    }
}

final class PlayerSurfaceView: NSView {
    var playerLayer: AVPlayerLayer?
    override var isFlipped: Bool { true }
    // Tell AppKit the view has no preferred size — fill whatever the parent
    // gives us. Without this, AVPlayerLayer's content size leaks through and
    // demands the video's native dimensions (e.g. 1920 wide for 1080p),
    // pushing the SwiftUI detail column off-screen.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
}

/// Inline "tag at the cut" capture. Appears over the player the moment you hit
/// Save so a clip is named / rated / tagged without ever opening the Inspector.
/// Enter (in the name field) saves; Esc cancels and keeps the in/out marks.
struct ClipCaptureCard: View {
    let durationMs: Int64
    let suggestions: [String]
    let onCommit: (String, Int, [String], [String]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var rating = 0
    @State private var selectedTags: Set<String> = []
    @State private var selectedPurposes: Set<String> = []
    @State private var newTag = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Title
            HStack(spacing: 7) {
                Image(systemName: "scissors").font(.system(size: 12)).foregroundStyle(Theme.success)
                Text("New clip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(PlayerController.formatMs(max(0, durationMs)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain).clipxIconButton(size: 24)
                    .accessibilityLabel("Cancel new clip")
            }

            // Name — autofocused, Enter saves.
            TextField("Name this clip…", text: $name)
                .accessibilityIdentifier("capture.name")
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .focused($nameFocused)
                .onSubmit(commit)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.r1))
                .overlay(RoundedRectangle(cornerRadius: Theme.r1).strokeBorder(Theme.borderStrong, lineWidth: 1))

            // Rating — the quality / keeper signal.
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Button { rating = (rating == i) ? 0 : i } label: {
                        Image(systemName: i <= rating ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(i <= rating ? Theme.star : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(i) star\(i == 1 ? "" : "s")")
                    .accessibilityValue(rating == i ? "Selected" : "")
                }
                Spacer()
            }

            // Purpose — what this clip is FOR (Coach, Reel, Publish…). The
            // primary fast-path axis; the vocabulary is user-configurable
            // (Settings → Labels) so it fits any kind of content.
            if !Purposes.active.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("for").clipxSectionLabel()
                    FlowLayout(spacing: 5) {
                        ForEach(Purposes.active) { label in
                            Button {
                                if selectedPurposes.contains(label.key) { selectedPurposes.remove(label.key) }
                                else { selectedPurposes.insert(label.key) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: label.symbol).font(.system(size: 10))
                                    Text(label.title)
                                }
                                .clipxChip(selected: selectedPurposes.contains(label.key))
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(selectedPurposes.contains(label.key) ? "Selected" : "Not selected")
                        }
                    }
                }
            }

            // Quick tags — what it's ABOUT. One-tap labels you already use, plus free entry.
            if !suggestions.isEmpty || !selectedTags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tagPalette, id: \.self) { tag in
                        ClipxToggleChip(label: tag, selected: selectedTags.contains(tag)) {
                            if selectedTags.contains(tag) { selectedTags.remove(tag) }
                            else { selectedTags.insert(tag) }
                        }
                    }
                }
            }

            // Add-a-tag + actions
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "tag").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    TextField("add tag", text: $newTag)
                        .accessibilityLabel("Add a tag")
                        .accessibilityIdentifier("capture.tag")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(addCurrentTag)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                .frame(maxWidth: 140)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Save clip", action: commit)
                    .accessibilityIdentifier("capture.save")
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            }
        }
        .padding(18)
        .frame(maxWidth: 390)
        .clipxPanel()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .onAppear { nameFocused = true }
    }

    /// Selected tags first, then remaining suggestions — so toggled chips don't
    /// jump around as the user picks them.
    private var tagPalette: [String] {
        let selectedList = selectedTags.sorted()
        let rest = suggestions.filter { !selectedTags.contains($0) }
        return selectedList + rest
    }

    private func addCurrentTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }
        selectedTags.insert(t)
        newTag = ""
    }

    private func commit() {
        addCurrentTag() // fold any half-typed tag in
        onCommit(name, rating, Array(selectedTags), Array(selectedPurposes))
    }
}

/// The current-time read-out in the control bar. A leaf that observes only the
/// `PlaybackClock`, so its 24–60Hz updates don't drag the whole player body
/// through a re-render on every frame.
struct PlaybackTimeLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(PlayerController.formatMs(clock.currentMs))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
    }
}
