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
            RemoteSettingsView()
                .tabItem { Label("Remote", systemImage: "iphone.gen3") }
            HotkeySettingsView()
                .tabItem { Label("Hotkeys", systemImage: "command") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 620, height: 500)
    }
}

/// Controls the embedded web server that powers the phone / laptop browser
/// frontend. Off by default — turning it on exposes a tiny HTTP server on
/// the local network bound to a high port.
struct RemoteSettingsView: View {
    @AppStorage("webServerEnabled") private var enabled: Bool = false
    @AppStorage("webServerPort") private var port: Int = 7878
    @State private var displayURL: String = ""

    var body: some View {
        Form {
            Section("Web UI") {
                Toggle("Serve Clipx web UI on this network", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        Task { @MainActor in
                            if newValue { AppEnvironment.shared.startWebServer() }
                            else { AppEnvironment.shared.stopWebServer() }
                            refreshURL()
                        }
                    }
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $port, format: .number.grouping(.never))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(enabled)
                }
                if enabled, !displayURL.isEmpty {
                    HStack {
                        Image(systemName: "link")
                        Text(displayURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(displayURL, forType: .string)
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text("Open this URL on your phone or laptop browser while on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if enabled {
                    Text("Couldn't determine your Mac's local IP — make sure Wi-Fi or Ethernet is connected.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("When enabled, your phone or laptop can browse sources and clips, and rate clips.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Label(
                    "No authentication yet. Don't enable on untrusted Wi-Fi (coffee shops, hotels).",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .font(.caption)
            }
        }
        .padding()
        .onAppear { refreshURL() }
    }

    private func refreshURL() {
        let ip = AppEnvironment.preferredLocalAddress()
        displayURL = ip.map { "http://\($0):\(port)" } ?? ""
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
            .onChange(of: appearance) { _, new in applyAppearance(new) }
            Toggle("Open clips in built-in player", isOn: $openInBuiltInPlayer)
        }
        .padding()
        .onAppear { applyAppearance(appearance) }
    }

    /// Pushes the user's appearance choice into NSApp so the whole window
    /// re-themes immediately. Without this the picker is a cosmetic no-op.
    private func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil // follow system
        }
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
    var body: some View {
        Form {
            Section("Player shortcuts") {
                ShortcutLabel(key: "I", label: "Mark In")
                ShortcutLabel(key: "O", label: "Mark Out")
                ShortcutLabel(key: "S", label: "Save Range as Clip")
                ShortcutLabel(key: "Space / K", label: "Play / Pause")
                ShortcutLabel(key: "← / →", label: "Step one frame")
                ShortcutLabel(key: "⇧← / ⇧→ or J / L", label: "Jump ±5s")
            }
            #if DIRECT_BUILD
            Section("Global") {
                ShortcutLabel(key: "⇧⌃⌘C", label: "Quick add to library (global hotkey)")
                Text("Rebinding is on the roadmap — defaults are locked for now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            Section {
                Label("Global hotkeys are unavailable in the Mac App Store build.",
                      systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .padding()
    }
}

/// Read-only shortcut row. Bookmark for when key-capture lands.
private struct ShortcutLabel: View {
    let key: String
    let label: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
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
