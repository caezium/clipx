import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void
    @EnvironmentObject private var appState: AppState
    @State private var step: Int
    @State private var obsidianPath = ""
    @State private var choosingFolder = false
    @State private var contentPreset = Purposes.activePresetID

    init(initialStep: Int = 0, onComplete: @escaping () -> Void) {
        _step = State(initialValue: min(3, max(0, initialStep)))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("clipx").font(Theme.wordmark(size: 24)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("Setup · \(step + 1) of 4").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case 0:
                        introduction(symbol: "scissors", title: "Welcome to Clipx",
                                     detail: "Find the moments you want to keep. Mark precise clips, organize them, and export when you're ready.")
                    case 1:
                        introduction(symbol: "folder.badge.plus", title: "Choose your footage",
                                     detail: "Choose a folder of videos. Clipx keeps it up to date as files arrive, while your originals stay untouched.")
                        Text("You can add more folders later with ⌘O, or drop a folder into the library.")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(16).frame(maxWidth: .infinity).clipxCard()
                    case 2:
                        introduction(symbol: "doc.text", title: "Connect Obsidian",
                                     detail: "Export clip notes and links to your vault. This is optional; you can connect a folder later in Settings.")
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                            Text(obsidianPath.isEmpty ? "No vault selected" : obsidianPath)
                                .font(.callout).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…", action: chooseVault)
                                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                        }
                        .padding(14).clipxCard()
                    default:
                        ready
                    }
                }
                .padding(.top, 8).padding(.bottom, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .padding(28)
        .frame(width: 624, height: 544)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .overlay(alignment: .top) { ToastStack(toasts: appState.toasts).padding(12) }
        .onAppear { obsidianPath = AppPreferences.defaults.string(forKey: "obsidianVaultPath") ?? "" }
    }

    private func introduction(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            introduction(symbol: "checkmark.circle", title: "You're ready to go",
                         detail: "Open a source video, then use these keys inside the player to save your first clip.")
            HStack {
                Text("I mostly make").font(.callout).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Content type", selection: $contentPreset) {
                    ForEach(Purposes.all) { preset in Text(preset.name).tag(preset.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 210)
                .onChange(of: contentPreset) { _, value in Purposes.activePresetID = value }
            }
            VStack(spacing: 10) {
                shortcut("I / O", "Mark In and Out")
                shortcut("S", "Save the marked range")
                shortcut("Space", "Play or pause")
                Divider().overlay(Theme.border)
                shortcut("⌘K", "Open the command palette")
                shortcut("⌘F", "Search the library")
            }
            .padding(14).clipxCard()
        }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Text(keys).clipxKeycap().frame(width: 70, alignment: .leading)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button("Back") { step -= 1 }.buttonStyle(PillButtonStyle(kind: .ghost))
            }
            Spacer()
            switch step {
            case 0:
                Button("Get Started") { step = 1 }.buttonStyle(PillButtonStyle(kind: .accent))
            case 1:
                Button("Skip for now") { step = 2 }.buttonStyle(PillButtonStyle(kind: .ghost))
                Button("Pick Folder…", action: chooseFootage).buttonStyle(PillButtonStyle(kind: .accent))
            case 2:
                Button("Skip") { step = 3 }.buttonStyle(PillButtonStyle(kind: .ghost))
                Button("Continue") { step = 3 }.buttonStyle(PillButtonStyle(kind: .accent))
                    .disabled(obsidianPath.isEmpty)
            default:
                Button("Open a video & start clipping", action: onComplete)
                    .buttonStyle(PillButtonStyle(kind: .accent))
            }
        }
        .disabled(choosingFolder)
    }

    private func chooseFootage() {
        choosingFolder = true
        Task { @MainActor in
            defer { choosingFolder = false }
            if let url = await FolderPicker.pickFolderURL(),
               AppEnvironment.shared.watcher?.add(folder: url) == true { step = 2 }
        }
    }

    private func chooseVault() {
        choosingFolder = true
        Task { @MainActor in
            defer { choosingFolder = false }
            if let url = await FolderPicker.pickFolderURL() {
                do {
                    try DestinationAccess.remember(url, for: .obsidianVault)
                    obsidianPath = url.path
                } catch {
                    appState.showToast("Couldn't connect vault: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }
}
