import Foundation

/// Store boundaries publish only after their transaction commits. Views use this
/// single signal for source, clip, and full-text result invalidation.
enum LibraryChanges {
    static func publish() {
        Task { @MainActor in AppState.shared.libraryRevision &+= 1 }
    }
}
