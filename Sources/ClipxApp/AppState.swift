import Foundation
import SwiftUI
import Combine

/// Shared, observable app state. Owns the currently-selected clip, search
/// query, and any other UI-wide reactive values. Heavy data layer
/// (database, indexer) lives in `AppEnvironment`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Selection
    @Published var selectedClipIDs: Set<Int64> = []
    @Published var selectedSourceID: Int64?
    @Published var selectedProjectID: Int64?
    @Published var selectedCollectionID: Int64?

    // MARK: Search & filters
    @Published var searchQuery: String = ""
    @Published var activeFilters = ClipFilters()
    @Published var commandPaletteOpen: Bool = false
    @Published var shortcutOverlayOpen: Bool = false
    @Published var exportProgressOpen: Bool = false

    // MARK: View modes
    @Published var viewMode: LibraryViewMode = .grid
    @Published var sortOption: ClipSortOption = .dateImportedDesc
    @Published var inspectorVisible: Bool = false

    // MARK: Player
    @Published var playerSourceID: Int64?
    @Published var playerInMs: Int64?
    @Published var playerOutMs: Int64?

    // MARK: Notifications
    @Published var toasts: [Toast] = []

    /// Bumped whenever the indexer writes a source. Views that display the
    /// library observe this to know when to re-query the database.
    @Published var libraryRevision: Int = 0

    /// Set to true by `AppEnvironment.bootstrap()` once the database and all
    /// services are ready. Views that need the env observe this so they don't
    /// race the bootstrap on first launch.
    @Published var bootstrapped: Bool = false

    private init() {}

    func showToast(_ message: String, level: ToastLevel = .info) {
        let toast = Toast(message: message, level: level)
        toasts.append(toast)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                toasts.removeAll { $0.id == toast.id }
            }
        }
    }
}

enum LibraryViewMode: String, CaseIterable {
    case grid
    case list
    case calendar
}

enum ClipSortOption: String, CaseIterable {
    // "Source date" — recording date from file metadata; this is the default
    // and what users actually want when they pick "newest" (you want to find
    // the day you filmed it, not the day you got around to importing).
    case sourceDateDesc
    case sourceDateAsc
    // Import-time sorts kept as explicit options for the cases where you
    // really do want "what I added today".
    case importedDesc
    case importedAsc
    // Legacy raw values kept so existing UserDefaults / persisted state still
    // load — both fold into source-date behavior.
    case dateImportedDesc
    case dateImportedAsc
    case ratingDesc
    case durationDesc
    case nameAsc

    var label: String {
        switch self {
        case .sourceDateDesc, .dateImportedDesc: return "Newest (filmed)"
        case .sourceDateAsc, .dateImportedAsc:   return "Oldest (filmed)"
        case .importedDesc: return "Recently imported"
        case .importedAsc:  return "First imported"
        case .ratingDesc:   return "Rating ↓"
        case .durationDesc: return "Longest first"
        case .nameAsc:      return "Name A→Z"
        }
    }

    /// Only show one entry for the source-date pair (the new canonical case)
    /// and one for the legacy variant — collapse duplicates in the picker.
    static var pickerCases: [ClipSortOption] {
        [.sourceDateDesc, .sourceDateAsc, .importedDesc, .importedAsc,
         .ratingDesc, .durationDesc, .nameAsc]
    }
}

struct ClipFilters: Equatable {
    var moods: Set<String> = []
    var shotTypes: Set<String> = []
    var cameraMoves: Set<String> = []
    var settings: Set<String> = []
    var colorLabels: Set<Int> = []
    var minRating: Int = 0
    var collectionIDs: Set<Int64> = []
    var projectIDs: Set<Int64> = []
    var dateFrom: Date?
    var dateTo: Date?
    var unusedOnly: Bool = false
    var onlineOnly: Bool = false

    var isActive: Bool {
        !moods.isEmpty || !shotTypes.isEmpty || !cameraMoves.isEmpty ||
        !settings.isEmpty || !colorLabels.isEmpty || minRating > 0 ||
        !collectionIDs.isEmpty || !projectIDs.isEmpty || dateFrom != nil ||
        dateTo != nil || unusedOnly || onlineOnly
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let level: ToastLevel
}

enum ToastLevel { case info, success, warning, error }
