import SwiftUI
import UniformTypeIdentifiers

/// The top-level layout: sidebar | library | inspector.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    @State private var inspectorVisible = true
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // Single-column content area. The player takes over when active so
            // it gets real horizontal space; library grid shows otherwise.
            if let sourceID = appState.playerSourceID {
                PlayerWorkspace(sourceID: sourceID)
            } else {
                HStack(spacing: 0) {
                    LibraryView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if appState.inspectorVisible, let clipID = appState.selectedClipIDs.first {
                        Divider()
                        InspectorView(clipID: clipID)
                            .frame(width: 300)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: appState.inspectorVisible)
            }
        }
        .navigationSplitViewStyle(.balanced)
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

/// Full-area player mode: header with back button, big player, optional
/// docked inspector on the right. Replaces the library while active so the
/// player gets real horizontal space.
private struct PlayerWorkspace: View {
    let sourceID: Int64
    @EnvironmentObject private var appState: AppState
    @State private var sourceName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Button {
                    appState.playerSourceID = nil
                    appState.playerInMs = nil
                    appState.playerOutMs = nil
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                .keyboardShortcut(.escape, modifiers: [])

                Text(sourceName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if appState.selectedClipIDs.first != nil {
                    Button {
                        appState.inspectorVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .buttonStyle(.plain)
                    .clipxIconButton(active: appState.inspectorVisible)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(appState.inspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.bgRaised)

            Divider().overlay(Theme.border)

            // Player + (optional) inspector
            HStack(spacing: 0) {
                PlayerView(sourceID: sourceID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if appState.inspectorVisible, let clipID = appState.selectedClipIDs.first {
                    Divider()
                    InspectorView(clipID: clipID)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: appState.inspectorVisible)
        }
        .onAppear(perform: loadName)
        .onChange(of: sourceID) { _, _ in loadName() }
    }

    private func loadName() {
        guard let db = AppEnvironment.shared.database else { return }
        if let src: Source = try? db.read({ try Source.fetchOne($0, key: sourceID) }) {
            sourceName = src.displayName
        }
    }
}
