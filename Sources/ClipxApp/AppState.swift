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

    // MARK: View modes
    @Published var viewMode: LibraryViewMode = .grid
    @Published var sortOption: ClipSortOption = .dateImportedDesc

    // MARK: Player
    @Published var playerSourceID: Int64?
    @Published var playerInMs: Int64?
    @Published var playerOutMs: Int64?

    // MARK: Notifications
    @Published var toasts: [Toast] = []

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

enum LibraryViewMode: String, CaseIterable { case grid, list }

enum ClipSortOption: String, CaseIterable {
    case dateImportedDesc
    case dateImportedAsc
    case ratingDesc
    case durationDesc
    case nameAsc

    var label: String {
        switch self {
        case .dateImportedDesc: return "Newest first"
        case .dateImportedAsc: return "Oldest first"
        case .ratingDesc: return "Rating ↓"
        case .durationDesc: return "Longest first"
        case .nameAsc: return "Name A→Z"
        }
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
