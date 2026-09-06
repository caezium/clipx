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
        guard let watcher = AppEnvironment.shared.watcher else {
            AppState.shared.showToast("Library still loading — try again in a moment", level: .warning)
            return
        }
        guard watcher.add(folder: url) else { return }
        AppState.shared.showToast("Added \(url.lastPathComponent) to library", level: .success)
    }
}
