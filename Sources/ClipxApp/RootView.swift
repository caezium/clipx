import SwiftUI
import UniformTypeIdentifiers

/// The top-level layout: sidebar | library | inspector.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    @State private var dropTargeted = false
    /// Drives the native search field's active state so ⌘F can focus it
    /// (macOS 14-compatible; `.searchFocused` is 15+).
    @State private var searchPresented = false
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
        NavigationSplitView {
            // ONE left column. It shows the library sidebar normally and the Cut
            // Room session rail while a source is open — a content swap *inside the
            // same column*, so we never stack two left columns (the recurring
            // sidebar-clip bug) and never have to force-collapse anything. The
            // framework sidebar toggle works in both modes to hide/show it.
            Group {
                if let sourceID = appState.playerSourceID {
                    SessionRailView(currentSourceID: sourceID) { id in
                        appState.playerSourceID = id
                        appState.playerInMs = nil
                        appState.playerOutMs = nil
                        appState.selectedClipIDs = []
                    }
                } else {
                    SidebarView()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // Single detail column: the player takes over when a source is open,
            // otherwise the library grid. The inspector is a framework-managed
            // trailing column (not a hand-built fixed-width HStack panel): AppKit
            // subtracts its width from the content, so sidebar + content +
            // inspector can never sum past the window and clip offscreen.
            Group {
                if let sourceID = appState.playerSourceID {
                    PlayerView(sourceID: sourceID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Native toolbar search — one clean system field, no
                        // custom pill (which doubled inside the toolbar item).
                        // Only present in the library, not the Cut Room.
                        .searchable(
                            text: $appState.searchQuery,
                            isPresented: $searchPresented,
                            placement: .toolbar,
                            prompt: "Search clips, tags, notes…"
                        )
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
                // Kept modest so sidebar + grid + inspector all stay usable near
                // the 900pt minimum window width (the grid isn't crushed).
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // ONE window toolbar for the whole app, whose content switches between
        // library and Cut Room. A single declaration (rather than one per child
        // view) keeps the shared toolbar from dropping items — especially the
        // .principal slot — when the detail view swaps.
        .toolbar { unifiedToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            // The search field only exists in the library toolbar; ignore ⌘F in
            // the Cut Room rather than activating a field that's gone.
            if !inPlayer { searchPresented = true }
        }
        // Keep the toolbar's source-name label in sync with the open source, and
        // dismiss any active search when entering the Cut Room.
        .onChange(of: appState.playerSourceID) { _, sourceID in
            if sourceID != nil { searchPresented = false }
            loadPlayerSourceName()
        }
        .onAppear { loadPlayerSourceName() }
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
        // The search field is the native `.searchable` on the library view
        // (see `body`) — a single system field, no custom pill inside the
        // toolbar item (which read as a doubled bar). The principal slot now
        // holds only the multi-select batch actions, when several are selected.
        if appState.selectedClipIDs.count > 1 {
            ToolbarItemGroup(placement: .principal) {
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
            .frame(width: 140)

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
            // Esc is handled in PlayerView (gated on !capturing) so it doesn't
            // fight the capture card's Cancel (.cancelAction) for the key.
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
