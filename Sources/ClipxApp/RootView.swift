import SwiftUI

/// The top-level layout: sidebar | library | inspector.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    @State private var inspectorVisible = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 220, idealWidth: 240)
        } content: {
            LibraryView()
                .frame(minWidth: 600)
        } detail: {
            if let sourceID = appState.playerSourceID {
                HStack(spacing: 0) {
                    PlayerView(sourceID: sourceID)
                        .frame(minWidth: 480)
                    if let clipID = appState.selectedClipIDs.first {
                        Divider()
                        InspectorView(clipID: clipID)
                            .frame(width: 340)
                    }
                }
            } else if let clipID = appState.selectedClipIDs.first {
                InspectorView(clipID: clipID)
                    .frame(minWidth: 340)
            } else {
                EmptyDetailView()
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

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Select a clip to preview")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("⌘K to open the command palette")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
