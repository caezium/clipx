import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "folder") }
            ExportSettingsView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            BridgesSettingsView()
                .tabItem { Label("Bridges", systemImage: "link") }
            HotkeySettingsView()
                .tabItem { Label("Hotkeys", systemImage: "command") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 620, height: 460)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("openClipsInBuiltInPlayer") private var openInBuiltInPlayer = true

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle("Open clips in built-in player", isOn: $openInBuiltInPlayer)
        }
        .padding()
    }
}

struct LibrarySettingsView: View {
    @State private var folders: [LibraryFolderDescriptor] = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("Library folders").font(.headline)
            List(folders, id: \.path) { folder in
                HStack {
                    Image(systemName: folder.online ? "folder.fill" : "folder.badge.questionmark")
                    Text(folder.path)
                    Spacer()
                    Text("\(folder.fileCount) files").foregroundStyle(.secondary).font(.caption)
                }
            }
            HStack {
                Button("Add Folder…") {
                    Task { @MainActor in await ImportCoordinator.shared.pickFolder() }
                }
                Spacer()
                Button("Rescan All") {
                    AppEnvironment.shared.watcher?.rescanAll()
                }
            }
        }
        .padding()
        .onAppear { reload() }
    }

    private func reload() {
        folders = AppEnvironment.shared.bookmarkStore?.allFolders() ?? []
    }
}

struct ExportSettingsView: View {
    var body: some View {
        Form {
            Text("Export presets are edited via the Export menu.").foregroundStyle(.secondary)
            #if MAS_BUILD
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio loudness normalization is unavailable in the Mac App Store build.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Link("Get the Direct version for -10/-14 LUFS exports",
                     destination: URL(string: "https://clipx.app/download")!)
            }
            .padding(.top)
            #endif
        }
        .padding()
    }
}

struct BridgesSettingsView: View {
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath: String = ""

    var body: some View {
        Form {
            Section("Obsidian") {
                HStack {
                    TextField("Vault folder", text: $obsidianVaultPath)
                    Button("Choose…") {
                        Task { @MainActor in
                            if let path = await FolderPicker.pickFolder() {
                                obsidianVaultPath = path
                            }
                        }
                    }
                }
                Text("Clipx writes a `.md` sidecar to this folder for each saved clip.")
                    .foregroundStyle(.secondary).font(.caption)
            }
            Section("FCPXML") {
                Text("FCPXML 1.13 is generated on demand via the Export menu.")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding()
    }
}

struct HotkeySettingsView: View {
    @AppStorage("hotkey.markIn") private var markIn = "I"
    @AppStorage("hotkey.markOut") private var markOut = "O"
    @AppStorage("hotkey.saveRange") private var saveRange = "S"
    @AppStorage("hotkey.globalQuickAdd") private var quickAdd = "Cmd+Shift+C"

    var body: some View {
        Form {
            HotkeyRow(label: "Mark In", binding: $markIn)
            HotkeyRow(label: "Mark Out", binding: $markOut)
            HotkeyRow(label: "Save Range as Clip", binding: $saveRange)
            #if DIRECT_BUILD
            Divider()
            HotkeyRow(label: "Global Quick-Add", binding: $quickAdd)
            #else
            Divider()
            Label("Global hotkeys are unavailable in the Mac App Store build.",
                  systemImage: "lock")
                .foregroundStyle(.secondary)
            #endif
        }
        .padding()
    }
}

private struct HotkeyRow: View {
    let label: String
    @Binding var binding: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $binding).frame(width: 120).textFieldStyle(.roundedBorder)
        }
    }
}

struct UpdatesSettingsView: View {
    var body: some View {
        Form {
            #if DIRECT_BUILD
            HStack {
                Text("Updates are delivered via Sparkle.")
                Spacer()
                Button("Check for Updates") {
                    UpdateManager.shared.checkForUpdates()
                }
            }
            Picker("Channel", selection: .constant("stable")) {
                Text("Stable").tag("stable")
                Text("Beta").tag("beta")
            }
            #else
            Text("Updates are delivered via the Mac App Store.").foregroundStyle(.secondary)
            #endif
        }
        .padding()
    }
}

struct LibraryFolderDescriptor: Equatable {
    let path: String
    let online: Bool
    let fileCount: Int
}
