import Foundation
import AppKit

/// Top-level export actions wired to menu items and the command palette.
enum ExportActions {
    static func exportSelected(_ preset: ExportPreset) {
        Task { @MainActor in
            let ids = AppState.shared.selectedClipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("No clips selected", level: .warning)
                return
            }
            #if MAS_BUILD
            if preset.requiresFFmpeg && preset.lufsTarget != nil {
                AppState.shared.showToast(
                    "Loudness normalization is unavailable in the MAS build. Using platform defaults.",
                    level: .warning
                )
            }
            #endif
            guard let outputDir = await pickOutputDirectory() else { return }
            for id in ids {
                AppEnvironment.shared.exportPipeline.enqueue(
                    clipID: id, preset: preset, outputDir: outputDir
                )
            }
            AppState.shared.showToast(
                "Queued \(ids.count) clip(s) as \(preset.displayName)",
                level: .info
            )
        }
    }

    static func exportFCPXML() {
        Task { @MainActor in
            let ids = AppState.shared.selectedClipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("No clips selected", level: .warning)
                return
            }
            guard let url = await saveDestination(suggested: "clipx-clips.fcpxml") else { return }
            do {
                try FCPXMLWriter.write(clipIDs: Array(ids), to: url)
                AppState.shared.showToast("FCPXML written", level: .success)
            } catch {
                AppState.shared.showToast("FCPXML failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    static func exportObsidian() {
        Task { @MainActor in
            let ids = AppState.shared.selectedClipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("No clips selected", level: .warning)
                return
            }
            let vaultPath = UserDefaults.standard.string(forKey: "obsidianVaultPath") ?? ""
            guard !vaultPath.isEmpty else {
                AppState.shared.showToast("Set the Obsidian vault path in Settings → Bridges", level: .warning)
                return
            }
            do {
                let count = try ObsidianWriter.writeSidecars(
                    clipIDs: Array(ids),
                    vaultPath: vaultPath
                )
                AppState.shared.showToast("Wrote \(count) Obsidian sidecar(s)", level: .success)
            } catch {
                AppState.shared.showToast("Obsidian write failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    @MainActor
    private static func pickOutputDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        let resp = await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { cont.resume(returning: $0) }
        }
        return resp == .OK ? panel.url : nil
    }

    @MainActor
    private static func saveDestination(suggested: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        let resp = await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { cont.resume(returning: $0) }
        }
        return resp == .OK ? panel.url : nil
    }
}
