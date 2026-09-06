import Foundation
import AppKit
import UniformTypeIdentifiers

/// Wraps NSOpenPanel for picking a folder. Returns the chosen path as a
/// String (the security-scoped bookmark is created by BookmarkStore).
enum FolderPicker {
    @MainActor
    static func pickFolder() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder of videos for Clipx to watch."
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { resp in continuation.resume(returning: resp) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }

    @MainActor
    static func pickFolderURL() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { resp in continuation.resume(returning: resp) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    @MainActor
    static func pickMarkdownNoteURL() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = "Choose Note"
        panel.message = "Choose an existing Markdown note to reference from this project."
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
