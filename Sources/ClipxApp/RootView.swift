import SwiftUI
import UniformTypeIdentifiers

/// Library navigation and a footage-first workspace with one task panel.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var libraryColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var showOnboarding = !AppPreferences.defaults.bool(forKey: "didCompleteOnboarding")
    @State private var dropTargeted = false
    /// Drives the native search field's active state so ⌘F can focus it
    /// (macOS 14-compatible; `.searchFocused` is 15+).
    @State private var searchPresented = false
    /// Display name of the source open in the player, shown in the toolbar.
    @State private var playerSourceName: String = ""

    /// True while a source is open in the player (the Cut Room).
    private var inPlayer: Bool { appState.playerSourceID != nil }

    /// Keep InspectorView mounted while its tab changes so drafts and pending
    /// saves belong to the clip, not to an individual tab.
    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Button { appState.inspectorTab = tab } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(appState.inspectorTab == tab ? Theme.textPrimary : Theme.textSecondary)
                            .background(appState.inspectorTab == tab ? Theme.surfaceActive : .clear,
                                        in: RoundedRectangle(cornerRadius: Theme.r2))
                            .contentShape(RoundedRectangle(cornerRadius: Theme.r2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inspector.tab.\(tab.rawValue)")
                    .accessibilityAddTraits(appState.inspectorTab == tab ? .isSelected : [])
                }
                Button { appState.inspectorVisible = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).clipxIconButton(size: 28)
                .help("Close panel (⌥⌘I)")
                .accessibilityLabel("Close clip panel")
            }
            .padding(12)

            if appState.selectedClipIDs.count == 1, let clipID = appState.selectedClipIDs.first {
                InspectorView(clipID: clipID).id(clipID)
            } else if appState.inspectorTab == .export, !appState.selectedClipIDs.isEmpty {
                ScrollView {
                    ClipExportView(clipIDs: appState.selectedClipIDs.sorted())
                        .padding(20)
                }
            } else {
                InspectorEmptyState(clipIDs: appState.selectedClipIDs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipxPanel()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // The native sidebar toggle exposes the source list in the player.
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            GeometryReader { geometry in
                let stacked = geometry.size.width < 780
                // AnyLayout preserves the player and inspector identity during
                // resizing. Two conditional copies would restart playback and
                // discard the focused editor when crossing the breakpoint.
                let layout = stacked
                    ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    Group {
                        if let sourceID = appState.playerSourceID {
                            PlayerView(sourceID: sourceID)
                        } else {
                            LibraryView()
                                .searchable(
                                    text: $appState.searchQuery,
                                    isPresented: $searchPresented,
                                    placement: .toolbar,
                                    prompt: "Search clips, tags, notes…"
                                )
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                    if appState.inspectorVisible {
                        inspectorPanel
                            .frame(width: stacked ? nil : min(340, geometry.size.width * 0.36),
                                   height: stacked ? min(280, geometry.size.height * 0.4) : nil)
                            .transition(.opacity)
                    }
                }
                .padding(16)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appState.inspectorVisible)
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
        .onChange(of: appState.playerSourceID) { previous, sourceID in
            if sourceID != nil {
                searchPresented = false
                if previous == nil {
                    libraryColumnVisibility = columnVisibility
                    columnVisibility = .detailOnly
                }
            } else if previous != nil {
                columnVisibility = libraryColumnVisibility
            }
            loadPlayerSourceName()
        }
        .onAppear {
            if inPlayer { columnVisibility = .detailOnly }
            loadPlayerSourceName()
        }
        .background(Theme.bg)
        .toolbarBackground(Theme.bgRaised, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
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
                AppPreferences.defaults.set(true, forKey: "didCompleteOnboarding")
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
            Button("Try Again") {
                appState.bootstrapError = nil
                AppEnvironment.shared.bootstrap()
            }
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
                Button { appState.selectedClipIDs = [] } label: {
                    Text("Clear").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
            .clipxToolbarChrome()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !appState.selectedClipIDs.isEmpty { exportPanelButton }
            Picker("Sort library", selection: $appState.sortOption) {
                ForEach(ClipSortOption.pickerCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("library.sort")
            .labelsHidden()
            .tint(Theme.textSecondary)
            .frame(width: 140)

            Picker("Library view", selection: $appState.viewMode) {
                Image(systemName: "calendar").accessibilityLabel("Calendar").tag(LibraryViewMode.calendar)
                Image(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").accessibilityLabel("List").tag(LibraryViewMode.list)
                Image(systemName: "tray.full").accessibilityLabel("Light Table").tag(LibraryViewMode.lightTable)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.viewMode")
            .frame(width: 150)
            .help("Calendar · Grid · List · Light Table")

            inspectorToggle
        }
        .clipxToolbarChrome()
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
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            // Esc is handled in PlayerView (gated on !capturing) so it doesn't
            // fight the capture card's Cancel (.cancelAction) for the key.
            .help("Back to library (Esc)")
        }
        .clipxToolbarChrome()
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                Text("Cut Room").foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                Text(playerSourceName)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .clipxToolbarChrome()
        ToolbarItemGroup(placement: .primaryAction) {
            if !appState.selectedClipIDs.isEmpty { exportPanelButton }
            inspectorToggle
        }
        .clipxToolbarChrome()
    }

    private var exportPanelButton: some View {
        Button { appState.showInspector(.export) } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .help("Export selected clips")
        .accessibilityIdentifier("workspace.export")
    }

    /// Shared inspector toggle — highlighted when active so its on/off state reads at
    /// a glance (two near-identical SF Symbols alone don't).
    private var inspectorToggle: some View {
        Button {
            appState.inspectorVisible.toggle()
        } label: {
            Image(systemName: appState.inspectorVisible ? "sidebar.trailing" : "sidebar.right")
        }
        .buttonStyle(.plain)
        .clipxIconButton(active: appState.inspectorVisible)
        .help(appState.inspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .keyboardShortcut("i", modifiers: [.command, .option])
        .accessibilityLabel(appState.inspectorVisible ? "Hide Inspector" : "Show Inspector")
        .accessibilityIdentifier("library.inspector")
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
        guard AppEnvironment.shared.watcher?.add(folder: folder) == true else { return }
        AppState.shared.showToast("Added \(folder.lastPathComponent) to library", level: .success)
    }
}

/// Placeholder shown in the inspector column when it's open but nothing is
/// selected — so toggling the inspector always reveals a panel (instead of
/// lighting the button with no visible change).
private struct InspectorEmptyState: View {
    @EnvironmentObject private var appState: AppState
    var clipIDs: Set<Int64> = []
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: clipIDs.isEmpty ? "sidebar.right" : "square.stack")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text(clipIDs.isEmpty ? "No clip selected" : "\(clipIDs.count) clips selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(clipIDs.isEmpty
                 ? "Select a saved clip to see its details, write notes, or export."
                 : "Select one clip to edit its details, or export the selected clips together.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            if !clipIDs.isEmpty {
                Button { appState.showInspector(.export) } label: {
                    Label("Export \(clipIDs.count) clips", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }
}
