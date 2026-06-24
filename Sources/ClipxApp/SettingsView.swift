import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            LabelsSettingsView()
                .tabItem { Label("Labels", systemImage: "tag") }
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
        .frame(width: 680, height: 600)
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Reusable settings scaffolding

/// Every page scrolls inside this so content never clips against the fixed
/// window height — the old pages cut off when they were taller than 500pt.
private struct SettingsScaffold<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// A titled, bordered group of settings rows.
private struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title).clipxSectionLabel().padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 13) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipxCard()
        }
    }
}

/// Wrapping descriptive caption. `fixedSize(vertical)` guarantees full text —
/// the previous pages let captions truncate.
private struct SettingsDesc: View {
    let text: String
    var tint: Color = Theme.textSecondary
    init(_ text: String, tint: Color = Theme.textSecondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
    }
}

private struct SettingsField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.r1))
            .overlay(RoundedRectangle(cornerRadius: Theme.r1).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("openClipsInBuiltInPlayer") private var openInBuiltInPlayer = true

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsScaffold {
            SettingsCard("Playback") {
                Toggle("Open clips in the built-in player", isOn: $openInBuiltInPlayer)
                    .font(.system(size: 13))
                SettingsDesc("When off, clips open in your default video app instead of the Clipx player.")
            }
            SettingsCard("About") {
                LabeledRow(label: "Version", value: appVersion)
                Divider().overlay(Theme.border)
                LabeledRow(label: "Appearance", value: "Dark (Clipx is dark-first)")
            }
        }
    }
}

// MARK: - Labels (purpose presets)

/// Picks the "purpose" vocabulary used on the fast path (capture panel) and in
/// the Light Table. Clipx is general-purpose, so the label set is swappable to
/// fit what you make — the default is the neutral Creator set.
struct LabelsSettingsView: View {
    @State private var presetID: String = Purposes.activePresetID

    private var activeLabels: [PurposeLabel] {
        (Purposes.all.first { $0.id == presetID } ?? Purposes.creator).labels
    }

    var body: some View {
        SettingsScaffold {
            SettingsCard("Purpose labels") {
                SettingsDesc("Clips are tagged by purpose on the fast path — what each one is FOR. Pick the starter set that fits what you make; these show up in the capture panel and the Light Table.")
                Picker("Content type", selection: $presetID) {
                    ForEach(Purposes.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.textSecondary)
                .onChange(of: presetID) { _, newValue in
                    Purposes.activePresetID = newValue
                    AppState.shared.libraryRevision &+= 1
                }
                Divider().overlay(Theme.border)
                FlowLayout(spacing: 6) {
                    ForEach(activeLabels) { label in
                        HStack(spacing: 4) {
                            Image(systemName: label.symbol).font(.system(size: 10))
                            Text(label.title)
                        }
                        .clipxChip(selected: true)
                    }
                }
            }
        }
    }
}

// MARK: - Library

struct LibrarySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var folders: [LibraryFolderDescriptor] = []

    var body: some View {
        SettingsScaffold {
            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in await ImportCoordinator.shared.pickFolder() }
                } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                Button {
                    AppEnvironment.shared.watcher?.rescanAll()
                } label: { Label("Rescan All", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                Button {
                    // Repair a desynced full-text search index. (#25)
                    do {
                        try AppEnvironment.shared.searchEngine?.rebuildIndex()
                        AppState.shared.showToast("Search index rebuilt", level: .success)
                    } catch {
                        AppState.shared.showToast("Rebuild failed: \(error.localizedDescription)", level: .error)
                    }
                } label: { Label("Rebuild Search Index", systemImage: "magnifyingglass") }
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                Spacer()
                Text("\(folders.count) folder\(folders.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }

            SettingsCard("Library Folders") {
                if folders.isEmpty {
                    SettingsDesc("No folders yet. Add a folder of footage and Clipx will index it and watch for new files.")
                } else {
                    ForEach(Array(folders.enumerated()), id: \.element.path) { idx, folder in
                        if idx > 0 { Divider().overlay(Theme.border) }
                        folderRow(folder)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: appState.libraryRevision) { _, _ in reload() }
    }

    private func folderRow(_ folder: LibraryFolderDescriptor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: folder.online ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 14))
                .foregroundStyle(folder.online ? Theme.accent : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(folder.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            }
            Spacer(minLength: 8)
            Text("\(folder.fileCount)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Text(folder.fileCount == 1 ? "file" : "files")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
            } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.plain)
                .clipxIconButton(size: 26)
                .help("Reveal in Finder")
            Button {
                // Stop watching + drop the folder record (sources stay indexed). (#35)
                AppEnvironment.shared.watcher?.remove(folderPath: folder.path)
                reload()
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .clipxIconButton(size: 26)
                .help("Remove from library")
        }
    }

    private func reload() {
        folders = AppEnvironment.shared.bookmarkStore?.allFolders() ?? []
    }
}

// MARK: - Export

struct ExportSettingsView: View {
    @AppStorage("exportDefaultFolder") private var exportFolder: String = ""

    var body: some View {
        SettingsScaffold {
            SettingsCard("Default destination") {
                HStack(spacing: 8) {
                    SettingsField(placeholder: "Ask every time…", text: $exportFolder)
                    Button("Choose…") {
                        Task { @MainActor in
                            if let path = await FolderPicker.pickFolder() { exportFolder = path }
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                    if !exportFolder.isEmpty {
                        Button("Clear") { exportFolder = "" }
                            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                    }
                }
                SettingsDesc("When set, exports write here without prompting. Leave empty to be asked each time. (#33)")
            }
            SettingsCard("Export") {
                SettingsDesc("Export presets are chosen per clip from the Export menu, the clip's right-click menu, or ⌘K → Export. Reels, TikTok, YouTube Shorts, Instagram Feed, YouTube 1080p/4K are built in.")
            }
            #if MAS_BUILD
            SettingsCard("Audio") {
                Label("Audio loudness normalization is unavailable in the Mac App Store build.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Link("Get the Direct version for −10/−14 LUFS exports",
                     destination: URL(string: "https://clipx.app/download")!)
                    .font(.system(size: 12))
            }
            #endif
        }
    }
}

// MARK: - Bridges

struct BridgesSettingsView: View {
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath: String = ""

    var body: some View {
        SettingsScaffold {
            SettingsCard("Obsidian") {
                HStack(spacing: 8) {
                    SettingsField(placeholder: "Vault folder…", text: $obsidianVaultPath)
                    Button("Choose…") {
                        Task { @MainActor in
                            if let path = await FolderPicker.pickFolder() {
                                obsidianVaultPath = path
                            }
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                }
                SettingsDesc("Clipx writes a Markdown sidecar to this folder for each saved clip, with its timecodes, rating, and tags.")
            }
            SettingsCard("FCPXML") {
                SettingsDesc("FCPXML 1.13 is generated on demand via the Export menu — drop it straight into a Final Cut Pro timeline.")
            }
        }
    }
}

// MARK: - Remote

/// Controls the embedded web server that powers the phone / laptop browser
/// frontend. Off by default — turning it on exposes a tiny HTTP server on
/// the local network bound to a high port.
struct RemoteSettingsView: View {
    @AppStorage("webServerEnabled") private var enabled: Bool = false
    @AppStorage("webServerPort") private var port: Int = 7878
    @State private var displayURL: String = ""
    @State private var pin: String = ""

    var body: some View {
        SettingsScaffold {
            SettingsCard("Web UI") {
                Toggle("Serve the Clipx web UI on this network", isOn: $enabled)
                    .font(.system(size: 13))
                    .onChange(of: enabled) { _, newValue in
                        Task { @MainActor in
                            if newValue {
                                AppEnvironment.shared.startWebServer()
                                pin = PairingStore.shared.pin
                            } else {
                                AppEnvironment.shared.stopWebServer()
                            }
                            refreshURL()
                        }
                    }
                Divider().overlay(Theme.border)
                HStack {
                    Text("Port").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TextField("", value: $port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.r1))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r1).strokeBorder(Theme.border, lineWidth: 1))
                        .disabled(enabled)
                        .opacity(enabled ? 0.5 : 1)
                }
                if !enabled {
                    SettingsDesc("When enabled, your phone or laptop can browse sources, watch clips, and mark new clips remotely.")
                }
            }

            if enabled, !displayURL.isEmpty {
                SettingsCard("Connection") {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Text(displayURL)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(displayURL, forType: .string)
                        }
                        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                    }
                    Divider().overlay(Theme.border)
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Text("Pairing PIN").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(pin)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.r1))
                            .textSelection(.enabled)
                        Button("New PIN") {
                            PairingStore.shared.rotate()
                            pin = PairingStore.shared.pin
                        }
                        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                        .help("Invalidates every paired device and generates a fresh code.")
                    }
                    SettingsDesc("Open the URL on your phone or laptop and type the PIN once. Tokens persist in browser storage; New PIN forces everyone to re-pair.")
                }
            } else if enabled {
                SettingsCard("Connection") {
                    Label("Couldn't determine your Mac's local IP — make sure Wi-Fi or Ethernet is connected.",
                          systemImage: "wifi.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard("Security") {
                Label("PIN auth is rate-limited only by your network — don't use this on coffee-shop Wi-Fi. Treat the URL like a password.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            refreshURL()
            if enabled { pin = PairingStore.shared.pin }
        }
    }

    private func refreshURL() {
        let ip = AppEnvironment.preferredLocalAddress()
        displayURL = ip.map { "http://\($0):\(port)" } ?? ""
    }
}

// MARK: - Hotkeys

struct HotkeySettingsView: View {
    var body: some View {
        SettingsScaffold {
            SettingsCard("Player") {
                shortcutRow("Mark In", "I")
                shortcutRow("Mark Out", "O")
                shortcutRow("Save Range as Clip", "S")
                shortcutRow("Play / Pause", "Space · K")
                shortcutRow("Step one frame", "← · →")
                shortcutRow("Jump ±5s", "⇧← ⇧→ · J L")
            }
            SettingsCard("App") {
                shortcutRow("Command Palette", "⌘K")
                shortcutRow("Search", "⌘F")
                shortcutRow("Import Folder", "⌘O")
                shortcutRow("Rescan Library Folders", "⌘R")
                shortcutRow("Toggle Inspector", "⌥⌘I")
                shortcutRow("Export as Reels", "⇧⌘R")
            }
            #if DIRECT_BUILD
            SettingsCard("Global") {
                shortcutRow("Quick add to library", "⇧⌃⌘C")
                SettingsDesc("Rebinding is on the roadmap — defaults are locked for now.")
            }
            #else
            SettingsCard("Global") {
                Label("Global hotkeys are unavailable in the Mac App Store build.",
                      systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            #endif
        }
    }

    private func shortcutRow(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            Spacer()
            KeyCap(text: key)
        }
    }
}

// MARK: - Updates

struct UpdatesSettingsView: View {
    @State private var channel = "stable"

    var body: some View {
        SettingsScaffold {
            #if DIRECT_BUILD
            SettingsCard("Updates") {
                HStack {
                    Text("Updates are delivered via Sparkle.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("Check for Updates") {
                        UpdateManager.shared.checkForUpdates()
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
                }
                Divider().overlay(Theme.border)
                HStack {
                    Text("Channel").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: $channel) {
                        Text("Stable").tag("stable")
                        Text("Beta").tag("beta")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            #else
            SettingsCard("Updates") {
                SettingsDesc("Updates are delivered via the Mac App Store.")
            }
            #endif
        }
    }
}

struct LibraryFolderDescriptor: Equatable {
    let path: String
    let online: Bool
    let fileCount: Int
}
