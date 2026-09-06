import Foundation
import AppKit

/// Top-level export actions wired to menu items and the command palette.
@MainActor
enum ExportActions {
    static func exportSelected(_ preset: ExportPreset) {
        export(clipIDs: AppState.shared.selectedClipIDs.sorted(), preset: preset)
    }

    /// Export an explicit set of clips without touching the global selection —
    /// used by surfaces (e.g. the Light Table) that export a group the user
    /// hasn't selected. `exportSelected` is the selection-driven wrapper.
    static func export(clipIDs: [Int64], preset: ExportPreset) {
        Task { @MainActor in
            let ids = clipIDs
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
            // Use the remembered default folder if set, else prompt. (#33)
            let destination: DestinationAccess
            do {
                if let remembered = try DestinationAccess.resolve(.exportFolder) {
                    destination = remembered
                } else if let picked = await pickOutputDirectory() {
                    destination = DestinationAccess.open(picked)
                } else {
                    return
                }
            } catch {
                AppState.shared.showToast(error.localizedDescription, level: .warning)
                guard let picked = await pickOutputDirectory() else { return }
                do { try DestinationAccess.remember(picked, for: .exportFolder) }
                catch {
                    AppState.shared.showToast("Couldn't remember the folder: \(error.localizedDescription)", level: .error)
                }
                destination = DestinationAccess.open(picked)
            }
            guard let pipeline = AppEnvironment.shared.exportPipeline else {
                AppState.shared.showToast("Export pipeline isn't ready yet", level: .warning)
                return
            }
            for id in ids {
                pipeline.enqueue(clipID: id, preset: preset, outputDir: destination.url, destination: destination)
            }
            AppState.shared.showToast(
                "Queued \(ids.count) clip(s) as \(preset.displayName)",
                level: .info
            )
        }
    }

    static func exportFCPXML() {
        exportFCPXML(clipIDs: AppState.shared.selectedClipIDs.sorted())
    }

    static func exportFCPXML(clipIDs: [Int64]) {
        Task { @MainActor in
            let ids = clipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("No clips selected", level: .warning)
                return
            }
            guard let url = await saveDestination(suggested: "clipx-clips.fcpxml") else { return }
            let access = DestinationAccess.open(url)
            defer { withExtendedLifetime(access) {} }
            do {
                try FCPXMLWriter.write(clipIDs: Array(ids), to: url)
                AppState.shared.showToast("FCPXML written", level: .success)
            } catch {
                AppState.shared.showToast("FCPXML failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    static func exportObsidian() {
        exportObsidian(clipIDs: AppState.shared.selectedClipIDs.sorted())
    }

    static func exportObsidian(clipIDs: [Int64]) {
        Task { @MainActor in
            let ids = clipIDs
            guard !ids.isEmpty else {
                AppState.shared.showToast("No clips selected", level: .warning)
                return
            }
            do {
                guard let destination = try DestinationAccess.resolve(.obsidianVault) else {
                    AppState.shared.showToast("Choose an Obsidian vault in Settings → Bridges", level: .warning)
                    return
                }
                defer { withExtendedLifetime(destination) {} }
                let count = try ObsidianWriter.writeSidecars(
                    clipIDs: Array(ids),
                    vaultPath: destination.url.path
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
