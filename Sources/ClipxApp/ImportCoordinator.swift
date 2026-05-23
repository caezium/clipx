import Foundation
import AppKit

/// Orchestrates the "user added a folder" flow: open NSOpenPanel, persist
/// the bookmark, start watching, kick off initial index.
@MainActor
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    private init() {}

    func pickFolder() async {
        guard let url = await FolderPicker.pickFolderURL() else { return }
        AppEnvironment.shared.watcher?.add(folder: url)
        AppState.shared.showToast("Added \(url.lastPathComponent) to library", level: .success)
    }
}
