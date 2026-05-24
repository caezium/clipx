import SwiftUI

/// The top-level layout: sidebar | library | inspector.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    @State private var inspectorVisible = true

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
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Text(sourceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                if appState.selectedClipIDs.first != nil {
                    Button {
                        appState.inspectorVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .foregroundStyle(appState.inspectorVisible ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(appState.inspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
