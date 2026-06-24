import SwiftUI
import UniformTypeIdentifiers

/// The top-level layout: sidebar | library | inspector.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    @State private var dropTargeted = false
    /// Drives the library sidebar's visibility. In the Cut Room (a source open
    /// in the player) the session rail *replaces* the library sidebar instead of
    /// stacking beside it — two left columns + the player + inspector overflow
    /// the window and clip both edges offscreen. Collapsing it keeps everything
    /// on screen and keeps the marking workspace focused.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Keyboard focus for the toolbar search field (⌘F).
    @FocusState private var searchFocused: Bool
    /// Display name of the source open in the player, shown in the toolbar.
    @State private var playerSourceName: String = ""

    /// True while a source is open in the player (the Cut Room).
    private var inPlayer: Bool { appState.playerSourceID != nil }

    /// The inspector column follows the toggle directly. It used to also require
    /// a selected clip, so toggling it on in the library (where nothing is
    /// selected) lit the button but showed no panel — it looked broken. Now the
    /// column always opens when toggled and shows a "No clip selected"
    /// placeholder until you pick a clip.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { appState.inspectorVisible },
            set: { appState.inspectorVisible = $0 }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // Single-column content area. The player takes over when active so
            // it gets real horizontal space; library grid shows otherwise. The
            // inspector is a framework-managed trailing column (not a hand-built
            // fixed-width HStack panel): AppKit subtracts its width from the
            // content, so sidebar + library + inspector can never sum past the
            // window and clip offscreen. (recurring sidebar-clip root-cause fix)
            Group {
                if let sourceID = appState.playerSourceID {
                    PlayerWorkspace(sourceID: sourceID)
                } else {
                    LibraryView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inspector(isPresented: inspectorPresented) {
                Group {
                    if let clipID = appState.selectedClipIDs.first {
                        InspectorView(clipID: clipID)
                    } else {
                        InspectorEmptyState()
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // ONE window toolbar for the whole app, whose content switches between
        // library and Cut Room. Previously LibraryView and PlayerWorkspace each
        // declared their own .toolbar; swapping those sibling views left the
        // shared toolbar with stale/dropped items (esp. the .principal slot).
        .toolbar { unifiedToolbar }
        // Drop the framework sidebar-toggle: the library sidebar's visibility is
        // driven here (collapsed in the Cut Room), and an exposed toggle let the
        // user re-stack the sidebar beside the session rail and clip offscreen.
        .toolbar(removing: .sidebarToggle)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            searchFocused = true
        }
        // Collapse the library sidebar in the Cut Room so the session rail is the
        // only left column; restore it back in the library. (sidebar-clip fix)
        .onChange(of: appState.playerSourceID) { _, sourceID in
            withAnimation(.easeInOut(duration: 0.18)) {
                columnVisibility = (sourceID != nil) ? .detailOnly : .all
            }
            loadPlayerSourceName()
        }
        .onAppear {
            columnVisibility = inPlayer ? .detailOnly : .all
            loadPlayerSourceName()
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Drop a folder (or video files) onto the window to add it. (#39)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                ZStack {
                    Theme.accent.opacity(0.08)
                    Text("Drop footage to add it to your library")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Theme.bgRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1.5))
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            ToastStack(toasts: appState.toasts)
                .padding(.top, 8)
        }
        .overlay {
            if appState.commandPaletteOpen {
                CommandPaletteView()
                    .transition(.opacity)
            }
            if appState.shortcutOverlayOpen {
                ShortcutOverlay(visible: $appState.shortcutOverlayOpen)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $appState.exportProgressOpen) {
            ExportProgressView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onComplete: {
                UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
                showOnboarding = false
            })
        }
        // Surface bootstrap failure so the user isn't stuck on an empty splash.
        .alert(
            "Clipx failed to start",
            isPresented: Binding(
                get: { appState.bootstrapError != nil },
                set: { if !$0 { appState.bootstrapError = nil } }
            ),
            presenting: appState.bootstrapError
        ) { _ in
            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
            Button("Continue Anyway", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Unified window toolbar

    /// Switches the single window toolbar between the library and the Cut Room.
    @ToolbarContentBuilder
    private var unifiedToolbar: some ToolbarContent {
        if inPlayer {
            playerToolbar
        } else {
            libraryToolbar
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search clips, tags, notes…", text: $appState.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onExitCommand { appState.searchQuery = "" }   // Esc clears (#38)
                    .frame(minWidth: 110)
                if !appState.searchQuery.isEmpty {
                    Button { appState.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            // Flexible (not a hard width) so the toolbar can compress on narrow
            // windows instead of pushing controls into the » overflow menu.
            .frame(maxWidth: 340)

            if appState.selectedClipIDs.count > 1 {
                Text("\(appState.selectedClipIDs.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Menu {
                    Button("Export as Reels") { ExportActions.exportSelected(.reels) }
                    Button("Export YouTube 1080p") { ExportActions.exportSelected(.youtube1080p) }
                    Button("Export YouTube 4K") { ExportActions.exportSelected(.youtube4k) }
                } label: {
                    Label("Export \(appState.selectedClipIDs.count)", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                Button { appState.selectedClipIDs = [] } label: {
                    Text("Clear").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $appState.sortOption) {
                ForEach(ClipSortOption.pickerCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.textSecondary)
            .frame(width: 150)

            Picker("", selection: $appState.viewMode) {
                Image(systemName: "calendar").tag(LibraryViewMode.calendar)
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                Image(systemName: "tray.full").tag(LibraryViewMode.lightTable)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Calendar · Grid · List · Light Table")

            inspectorToggle
        }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                appState.playerSourceID = nil
                appState.playerInMs = nil
                appState.playerOutMs = nil
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back to library (Esc)")
        }
        ToolbarItem(placement: .principal) {
            Text(playerSourceName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.textPrimary)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            inspectorToggle
        }
    }

    /// Shared inspector toggle — tinted when active so its on/off state reads at
    /// a glance (two near-identical SF Symbols alone don't).
    private var inspectorToggle: some View {
        Button {
            appState.inspectorVisible.toggle()
        } label: {
            Image(systemName: appState.inspectorVisible ? "sidebar.trailing" : "sidebar.right")
                .foregroundStyle(appState.inspectorVisible ? Theme.accent : Theme.textSecondary)
        }
        .help(appState.inspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .keyboardShortcut("i", modifiers: [.command, .option])
    }

    private func loadPlayerSourceName() {
        guard let id = appState.playerSourceID, let db = AppEnvironment.shared.database else {
            playerSourceName = ""
            return
        }
        if let src: Source = try? db.read({ try Source.fetchOne($0, key: id) }) {
            playerSourceName = src.displayName
        }
    }
}

extension RootView {
    fileprivate func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in addDroppedURL(url) }
            }
        }
        return handled
    }

    @MainActor
    fileprivate func addDroppedURL(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        // A dropped folder is watched directly; a dropped video adds its
        // containing folder. (#39)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        AppEnvironment.shared.watcher?.add(folder: folder)
        AppState.shared.showToast("Added \(folder.lastPathComponent) to library", level: .success)
    }
}

/// Placeholder shown in the inspector column when it's open but nothing is
/// selected — so toggling the inspector always reveals a panel (instead of
/// lighting the button with no visible change).
private struct InspectorEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("No clip selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Select a clip to see its rating, tags, attributes, and export options.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgRaised)
    }
}

/// Full-area player mode: header with back button, big player, optional
/// docked inspector on the right. Replaces the library while active so the
/// player gets real horizontal space.
private struct PlayerWorkspace: View {
    let sourceID: Int64
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // The toolbar (back, source name, inspector toggle) lives in RootView's
        // single unified toolbar — this view is just the session rail + player.
        HStack(spacing: 0) {
            // Session rail: the day's footage as a working stack with per-source
            // review progress. Picking a row switches the player in place.
            SessionRailView(currentSourceID: sourceID) { id in
                appState.playerSourceID = id
                appState.playerInMs = nil
                appState.playerOutMs = nil
                appState.selectedClipIDs = []
            }

            Divider().overlay(Theme.border)

            // Player fills the rest; the inspector is a framework-managed
            // trailing column owned by RootView (see .inspector above).
            PlayerView(sourceID: sourceID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
