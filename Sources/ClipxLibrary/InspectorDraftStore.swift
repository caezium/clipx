import Foundation

/// Drafts belong to the clip, so replacing an inspector view cannot discard a
/// failed write. Successful navigation flushes synchronously; a failed draft is
/// available again when its clip is selected or the retry action is used.
@MainActor
final class InspectorDraftStore {
    static let shared = InspectorDraftStore()

    struct Draft {
        var name: String
        var notes: String
        let savedName: String
        let savedNotes: String
        var hasChanges: Bool { name != savedName || notes != savedNotes }
    }

    private var drafts: [Int64: Draft] = [:]

    func draft(for clip: Clip) -> Draft {
        if let id = clip.id, let draft = drafts[id] { return draft }
        return Draft(name: clip.name ?? "", notes: clip.notes ?? "",
                     savedName: clip.name ?? "", savedNotes: clip.notes ?? "")
    }

    func record(clip: Clip, name: String, notes: String) {
        guard let id = clip.id else { return }
        var value = draft(for: clip)
        value.name = name
        value.notes = notes
        drafts[id] = value
    }

    @discardableResult
    func flush(_ clipID: Int64, store: MarkerStore) throws -> Clip? {
        guard let draft = drafts[clipID] else { return nil }
        var saved: Clip?
        if draft.hasChanges {
            saved = try store.updateDraft(clipID,
                                  name: draft.name == draft.savedName ? .unchanged : .set(draft.name.isEmpty ? nil : draft.name),
                                  notes: draft.notes == draft.savedNotes ? .unchanged : .set(draft.notes.isEmpty ? nil : draft.notes),
                                  baselineNotes: draft.savedNotes)
        }
        drafts.removeValue(forKey: clipID)
        return saved
    }

    func hasPendingChanges(_ clipID: Int64) -> Bool { drafts[clipID]?.hasChanges == true }
}
