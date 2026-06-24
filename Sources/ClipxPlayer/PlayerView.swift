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
    @State private var savedClips: [Clip] = []
    @FocusState private var keyboardFocused: Bool
    // Tag-at-the-cut: pressing Save opens an inline capture instead of writing a
    // nameless clip and forcing a trip to the Inspector.
    @State private var capturing = false
    @State private var captureSuggestions: [String] = []

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
                        .onTapGesture { if !capturing { keyboardFocused = true } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(-1)
            // The capture card floats over the bottom of the video so marking
            // → naming → tagging never leaves the player.
            .overlay(alignment: .bottom) {
                if capturing {
                    captureCard
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Skimmable filmstrip timeline: the source's sampled frames drawn
            // across the width so a long source is visually scannable, with the
            // in/out band, saved-clip pins, and playhead over it.
            FilmstripTimelineView(
                controller: controller,
                sourceHash: source?.hash,
                sourceURL: source?.url,
                savedClips: savedClips,
                onSelectClip: { clip in
                    appState.playerInMs = clip.inMs
                    appState.playerOutMs = clip.outMs
                    controller.seek(toMs: clip.inMs)
                }
            )
            .frame(height: 76)
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
        .onReceive(NotificationCenter.default.publisher(for: .systemWillSleep)) { _ in
            controller.pause()
        }
        .onDisappear { controller.tearDown() }
        // All player hotkeys route through `key()`, which returns `.ignored`
        // while a text field is being edited (the capture card's name/tag
        // fields, etc.) so typing "s" doesn't fire Save. (onKeyPress on this
        // container otherwise also receives keys aimed at focused descendants.)
        .onKeyPress("i") { key { markIn() } }
        .onKeyPress("o") { key { markOut() } }
        .onKeyPress("s") { key { saveRange() } }
        .onKeyPress(.space) { key { controller.togglePlayPause() } }
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
        // Menu commands and command palette post these notifications. We observe
        // them here so the menu drives whichever player is currently visible.
        .onReceive(NotificationCenter.default.publisher(for: .markIn)) { _ in markIn() }
        .onReceive(NotificationCenter.default.publisher(for: .markOut)) { _ in markOut() }
        .onReceive(NotificationCenter.default.publisher(for: .saveRange)) { _ in saveRange() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepBack)) { _ in controller.stepBackward() }
        .onReceive(NotificationCenter.default.publisher(for: .playerStepForward)) { _ in controller.stepForward() }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            // Transport cluster: -5s | prev frame | play/pause | next frame | +5s
            HStack(spacing: 2) {
                Button { controller.jumpBackward(seconds: 5) } label: {
                    Image(systemName: "gobackward.5").font(.system(size: 15))
                }
                .buttonStyle(.plain).clipxIconButton()
                .help("Back 5s (J or ⇧←)")

                Button { controller.stepBackward() } label: {
                    Image(systemName: "backward.frame.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).clipxIconButton()
                .help("Previous frame (←)")

                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain).clipxIconButton(size: 36, active: false)
                .help("Play / Pause (Space or K)")

                Button { controller.stepForward() } label: {
                    Image(systemName: "forward.frame.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).clipxIconButton()
                .help("Next frame (→)")

                Button { controller.jumpForward(seconds: 5) } label: {
                    Image(systemName: "goforward.5").font(.system(size: 15))
                }
                .buttonStyle(.plain).clipxIconButton()
                .help("Forward 5s (L or ⇧→)")
            }

            // Time display
            HStack(spacing: 4) {
                Text(controller.currentTimeLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                Text("/").foregroundStyle(Theme.textTertiary)
                Text(controller.durationLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.surface, in: Capsule())

            // In/Out range indicator
            if let inMs = appState.playerInMs {
                HStack(spacing: 4) {
                    Image(systemName: "scissors").font(.caption2)
                    Text(PlayerController.formatMs(inMs))
                        .font(.caption.monospacedDigit())
                    if let outMs = appState.playerOutMs {
                        Text("→")
                        Text(PlayerController.formatMs(outMs))
                            .font(.caption.monospacedDigit())
                        Text("(\(PlayerController.formatMs(outMs - inMs)))")
                            .font(.caption2.monospacedDigit())
                            .opacity(0.8)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.success.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.success.opacity(0.35), lineWidth: 1))
                .foregroundStyle(Theme.success)
                .fixedSize()
            }

            Spacer()

            // Rotate 90° — persists per source and is baked into exports.
            Button { rotate() } label: {
                Image(systemName: "rotate.right").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .clipxIconButton(active: controller.rotation != 0)
            .help(controller.rotation == 0 ? "Rotate 90°" : "Rotated \(controller.rotation)° — click to rotate")

            // Mark cluster
            HStack(spacing: 6) {
                Button { markIn() } label: {
                    Label("In", systemImage: "i.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .fixedSize()
                .help("Mark In (I)")
                Button { markOut() } label: {
                    Label("Out", systemImage: "o.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .fixedSize()
                .help("Mark Out (O)")
                Button { saveRange() } label: {
                    Label("Save Clip", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(kind: .accent, compact: true))
                .fixedSize()
                // No keyboardShortcut here — menu shortcuts hijack focused
                // TextFields. The .onKeyPress("s") on the view handles the
                // keyboard path when the player has focus.
                .help("Save range as clip (S)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.bgRaised)
    }

    private func load() {
        guard let database = AppEnvironment.shared.database else { return }
        do {
            guard let src: Source = try database.read({
                try Source.fetchOne($0, key: sourceID)
            }) else { return }
            self.source = src
            controller.load(url: src.url)
            controller.setRotation(src.rotation)   // restore the source's rotation
            if let inMs = appState.playerInMs {
                controller.seek(toMs: inMs)
            }
        } catch {
            ClipxLog.player.error("PlayerView.load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs `action` and consumes the key — unless a text field is being edited
    /// (the capture card's name/tag fields, etc.), in which case the key is
    /// ignored so it reaches the field instead of firing a player shortcut.
    private func key(_ action: () -> Void) -> KeyPress.Result {
        if capturing || PlayerView.isEditingText() { return .ignored }
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
        controller.setRotation(newRotation)
        guard var src = source, let id = src.id else { return }
        src.rotation = newRotation
        source = src
        try? AppEnvironment.shared.database?.write { db in
            try db.execute(sql: "UPDATE sources SET rotation = ? WHERE id = ?", arguments: [newRotation, id])
        }
        AppState.shared.libraryRevision &+= 1
    }

    private func markIn() {
        // Snap to the displayed frame so the mark matches what the user saw. (#14)
        appState.playerInMs = controller.currentFrameMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    private func markOut() {
        appState.playerOutMs = controller.currentFrameMs
        NotificationCenter.default.post(name: .markerDidChange, object: nil)
    }

    /// Save (S) no longer writes a nameless clip — it opens the inline capture
    /// so the clip is named, tagged, and rated at the moment of the cut.
    private func saveRange() {
        guard !capturing else { return }
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
                name: trimmedName.isEmpty ? nil : trimmedName
            )
            if let id = clip.id {
                if rating > 0 { try? markerStore.updateRating(id, rating: rating) }
                if !purposes.isEmpty {
                    try? markerStore.updatePurpose(id, purpose: purposes.joined(separator: ","))
                }
                if let tagStore = AppEnvironment.shared.tagStore {
                    for tag in tags { try? tagStore.addTag(tag, toClip: id) }
                }
            }
            let count = savedClips.count + 1
            AppState.shared.showToast(
                trimmedName.isEmpty
                    ? "Saved clip \(count) (\(PlayerController.formatMs(outMs - inMs)))"
                    : "Saved “\(trimmedName)” (\(PlayerController.formatMs(outMs - inMs)))",
                level: .success
            )
            // Park just past the out point so the next clip can be marked without
            // re-scrubbing. Reload of the strip happens via libraryRevision.
            controller.seek(toMs: outMs)
            appState.playerInMs = nil
            appState.playerOutMs = nil
        } catch {
            AppState.shared.showToast("Failed to save: \(error.localizedDescription)", level: .error)
        }
        withAnimation(.easeOut(duration: 0.16)) { capturing = false }
        keyboardFocused = true
    }

    private func cancelCapture() {
        // Keep the in/out marks so the user can re-scrub and try again.
        withAnimation(.easeOut(duration: 0.16)) { capturing = false }
        keyboardFocused = true
    }

    private var captureCard: some View {
        ClipCaptureCard(
            durationMs: (appState.playerOutMs ?? 0) - (appState.playerInMs ?? 0),
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
        Task.detached(priority: .userInitiated) { [sourceID] in
            guard let store = AppEnvironment.shared.markerStore else { return }
            let clips = (try? store.fetchClips(forSource: sourceID)) ?? []
            await MainActor.run { self.savedClips = clips }
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
        .background(Theme.bgRaised)
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
                Text(PlayerController.formatMs(clip.outMs - clip.inMs))
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
                    appState.inspectorVisible = true
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
        appState.selectedClipIDs = [clipID]
        ExportActions.exportSelected(preset)
    }

    private func deleteClip(_ clipID: Int64) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        do {
            try markerStore.deleteClip(clipID)
            appState.selectedClipIDs.remove(clipID)
            AppState.shared.showToast("Clip deleted", level: .info)
        } catch {
            AppState.shared.showToast("Delete failed: \(error.localizedDescription)", level: .error)
        }
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
            }

            // Name — autofocused, Enter saves.
            TextField("Name this clip…", text: $name)
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
                Button("Save", action: commit)
                    .buttonStyle(PillButtonStyle(kind: .accent, compact: true))
            }
        }
        .padding(14)
        .frame(width: 390)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.r3))
        .background(Theme.surfaceActive, in: RoundedRectangle(cornerRadius: Theme.r3))
        .overlay(RoundedRectangle(cornerRadius: Theme.r3).strokeBorder(Theme.borderStrong, lineWidth: 1))
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
