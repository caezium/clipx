import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void
    @State private var step: Int = 0

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case 0: welcome
            case 1: pickLibraryFolder
            case 2: pickObsidian
            default: ready
            }
        }
        .frame(width: 560, height: 400)
        .padding(32)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "scissors").font(.system(size: 64))
            Text("Welcome to Clipx").font(.largeTitle.bold())
            Text("The fastest way to mark, find, and export clips.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = 1 }.controlSize(.large).buttonStyle(.borderedProminent)
        }
    }

    private var pickLibraryFolder: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus").font(.system(size: 48))
            Text("Choose your library folder").font(.title.bold())
            Text("Clipx watches one or more folders for video files and indexes them in the background.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pick Folder…") {
                Task { @MainActor in
                    if let url = await FolderPicker.pickFolderURL() {
                        AppEnvironment.shared.watcher?.add(folder: url)
                        step = 2
                    }
                }
            }.controlSize(.large).buttonStyle(.borderedProminent)
            Button("Skip for now") { step = 2 }.controlSize(.regular)
        }
    }

    @State private var obsidianPath: String = ""
    private var pickObsidian: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text").font(.system(size: 48))
            Text("Connect Obsidian (optional)").font(.title.bold())
            Text("Clipx can write a `.md` sidecar to your Obsidian vault for each clip you save, so your library lives in your second brain.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Vault folder", text: $obsidianPath)
                Button("Choose…") {
                    Task { @MainActor in
                        if let path = await FolderPicker.pickFolder() {
                            obsidianPath = path
                            UserDefaults.standard.set(path, forKey: "obsidianVaultPath")
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Button("Skip") { step = 3 }
                Button("Continue") {
                    UserDefaults.standard.set(obsidianPath, forKey: "obsidianVaultPath")
                    step = 3
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("You're ready to go").font(.title.bold())
            VStack(alignment: .leading, spacing: 8) {
                Label("I / O — Mark in / out", systemImage: "command")
                Label("S — Save range as clip", systemImage: "command")
                Label("⌘K — Command palette", systemImage: "command")
                Label("Space — Play / pause", systemImage: "command")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Spacer()
            Button("Start clipping") { onComplete() }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
    }
}
