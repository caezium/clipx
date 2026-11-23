import Foundation
import SwiftUI
import Combine
import AppKit

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
    // Default to the calendar/date-grouped view: launch should land on "find the
    // shoot from Saturday", not a wall of 100+ mixed sources and clips.
    @Published var viewMode: LibraryViewMode = .calendar
    @Published var sortOption: ClipSortOption = .sourceDateDesc
    @Published var inspectorVisible: Bool = false
    @Published var inspectorTab: InspectorTab = .details
    @Published var inspectorExportPreset: ExportPreset = .reels

    func showInspector(_ tab: InspectorTab) {
        inspectorTab = tab
        inspectorVisible = true
    }

    // MARK: Player
    @Published var playerSourceID: Int64?
    @Published var playerInMs: Int64?
    @Published var playerOutMs: Int64?
    @Published var playerOpenRevision = 0

    func openClip(_ clip: Clip) {
        if let id = clip.id { selectedClipIDs = [id] }
        guard clip.durationMs > 0 else {
            showToast("This clip has an invalid range. Open its source to mark a new range.", level: .error)
            return
        }
        if AppPreferences.defaults.object(forKey: "openClipsInBuiltInPlayer") as? Bool == false {
            do {
                guard let database = AppEnvironment.shared.database,
                      let source = try database.read({ try Source.fetchOne($0, key: clip.sourceID) }),
                      NSWorkspace.shared.open(source.url) else {
                    showToast("Couldn't open this source in your default video app", level: .error)
                    return
                }
            } catch { showToast("Couldn't open source: \(error.localizedDescription)", level: .error) }
            return
        }
        playerInMs = clip.inMs
        playerOutMs = clip.outMs
        playerSourceID = clip.sourceID
        playerOpenRevision &+= 1
    }

    /// Navigation scope and its query filters change together.
    func selectProject(_ id: Int64?) {
        selectedProjectID = id
        selectedCollectionID = nil
        activeFilters.projectIDs = id.map { [$0] } ?? []
        activeFilters.collectionIDs = []
    }

    func selectCollection(_ id: Int64?) {
        selectedCollectionID = id
        selectedProjectID = nil
        activeFilters.collectionIDs = id.map { [$0] } ?? []
        activeFilters.projectIDs = []
    }

    func clearFilters() {
        selectedProjectID = nil
        selectedCollectionID = nil
        activeFilters = ClipFilters()
    }

    // MARK: Notifications
    @Published var toasts: [Toast] = []

    /// Bumped whenever the indexer writes a source. Views that display the
    /// library observe this to know when to re-query the database.
    @Published var libraryRevision: Int = 0

    /// Set to true by `AppEnvironment.bootstrap()` once the database and all
    /// services are ready. Views that need the env observe this so they don't
    /// race the bootstrap on first launch.
    @Published var bootstrapped: Bool = false

    /// Set when `AppEnvironment.bootstrap()` throws. RootView observes this and
    /// surfaces a blocking alert with the message + quit option, so the user
    /// isn't stuck staring at an empty splash with no explanation.
    @Published var bootstrapError: String?

    private init() {}

    /// Per-toast dismissal task. Cancelled if the toast is removed early (e.g.
    /// user explicitly dismisses) so we don't leak suspended sleeps.
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    /// Action handlers for toasts that offer an affordance (e.g. "Undo"). Kept
    /// out of `Toast` so it stays `Equatable`. (#30)
    private var toastActions: [UUID: () -> Void] = [:]

    /// Run (and consume) a toast's action, then dismiss it.
    func runToastAction(_ id: UUID) {
        let action = toastActions[id]
        dismissToast(id)
        action?()
    }

    func showToast(
        _ message: String,
        level: ToastLevel = .info,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        let toast = Toast(message: message, level: level, actionLabel: actionLabel)
        if let action { toastActions[toast.id] = action }
        toasts.append(toast)
        // Cap visible toast count so a save-storm doesn't bury the UI.
        if toasts.count > 5 {
            let removed = toasts.removeFirst()
            dismissTasks.removeValue(forKey: removed.id)?.cancel()
            toastActions.removeValue(forKey: removed.id)
        }
        let id = toast.id
        // Toasts that offer an action (e.g. Undo) linger longer. (#30)
        let ttl: UInt64 = actionLabel != nil ? 6_000_000_000 : 3_000_000_000
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ttl)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismissToast(id)
            }
        }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        dismissTasks.removeValue(forKey: id)?.cancel()
        toastActions.removeValue(forKey: id)
    }
}

/// Shared by the library and player; changing clips keeps the current task open.
enum InspectorTab: String, CaseIterable {
    case details, notes, export

    var title: String {
        switch self {
        case .details: return "Details"
        case .notes: return "Notes"
        case .export: return "Export"
        }
    }
}

enum LibraryViewMode: String, CaseIterable {
    case grid
    case list
    case calendar
    /// The harvest surface — marked clips grouped by purpose, goal-first export.
    case lightTable
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
    enum DateField: String { case recorded, imported }
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
    var dateField: DateField = .recorded
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
    var actionLabel: String? = nil
}

enum ToastLevel { case info, success, warning, error }
