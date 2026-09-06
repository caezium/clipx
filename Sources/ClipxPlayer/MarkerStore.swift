import Foundation
import GRDB

/// CRUD on the clips table. Marker semantics live here so the UI and the
/// keyboard-shortcut layer share the same validation.
final class MarkerStore {
    private let database: Database
    private let didChange: () -> Void

    init(database: Database, didChange: @escaping () -> Void = LibraryChanges.publish) {
        self.database = database
        self.didChange = didChange
    }

    /// Saves a new clip range. Returns the inserted clip with its id populated.
    @discardableResult
    func saveRange(sourceID: Int64, inMs: Int64, outMs: Int64, name: String? = nil,
                   rating: Int = 0, tags: [String] = [], purposes: [String] = [],
                   projectIDs: [Int64] = [], collectionIDs: [Int64] = []) throws -> Clip {
        var clip = Clip(
            id: nil,
            sourceID: sourceID,
            name: name,
            inMs: inMs,
            outMs: outMs,
            rating: max(0, min(5, rating)),
            colorLabel: nil,
            mood: nil,
            shotType: nil,
            cameraMove: nil,
            setting: nil,
            notes: nil,
            createdAt: Int64(Date().timeIntervalSince1970),
            usedCount: 0
        )
        clip.purpose = purposes.isEmpty ? nil : Array(Set(purposes)).sorted().joined(separator: ",")
        try database.write { db in
            try Self.validateRange(db, sourceID: sourceID, inMs: inMs, outMs: outMs)
            try clip.insert(db)
            let id = clip.id!
            for tag in tags { try TagStore.addTag(tag, toClip: id, in: db) }
            for projectID in Set(projectIDs) {
                try db.execute(sql: "INSERT INTO clip_projects(clip_id, project_id) VALUES (?, ?)", arguments: [id, projectID])
            }
            for collectionID in Set(collectionIDs) {
                try db.execute(sql: "INSERT INTO clip_collections(clip_id, collection_id) VALUES (?, ?)", arguments: [id, collectionID])
            }
        }
        didChange()
        return clip
    }

    func updateRating(_ clipID: Int64, rating: Int) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET rating = ? WHERE id = ?",
                arguments: [max(0, min(5, rating)), clipID]
            )
        }
        didChange()
    }

    func updateColorLabel(_ clipID: Int64, label: Int?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET color_label = ? WHERE id = ?",
                arguments: [label, clipID]
            )
        }
        didChange()
    }

    func updateRange(_ clipID: Int64, inMs: Int64, outMs: Int64) throws {
        try database.write { db in
            guard let clip = try Clip.fetchOne(db, key: clipID) else { throw MarkerError.clipNotFound(clipID) }
            try Self.validateRange(db, sourceID: clip.sourceID, inMs: inMs, outMs: outMs)
            try db.execute(
                sql: "UPDATE clips SET in_ms = ?, out_ms = ? WHERE id = ?",
                arguments: [inMs, outMs, clipID]
            )
        }
        didChange()
    }

    private static func validateRange(_ db: GRDB.Database, sourceID: Int64, inMs: Int64, outMs: Int64) throws {
        guard inMs >= 0, outMs > inMs else { throw MarkerError.invalidRange(inMs: inMs, outMs: outMs) }
        guard let source = try Source.fetchOne(db, key: sourceID) else { throw MarkerError.sourceNotFound(sourceID) }
        if let duration = source.durationMs, duration > 0, outMs > duration {
            throw MarkerError.invalidRange(inMs: inMs, outMs: outMs)
        }
    }

    func updateName(_ clipID: Int64, name: String?) throws {
        try updateText(clipID, column: "name", value: name)
    }

    func updateNotes(_ clipID: Int64, notes: String?) throws {
        try updateText(clipID, column: "notes", value: notes)
    }

    @discardableResult
    func updateDraft(_ clipID: Int64, name: FieldUpdate<String>, notes: FieldUpdate<String>,
                     baselineNotes: String? = nil) throws -> Clip {
        let saved = try database.write { db -> Clip in
            guard let current = try Clip.fetchOne(db, key: clipID) else { throw MarkerError.clipNotFound(clipID) }
            if case .set(let value) = name {
                try db.execute(sql: "UPDATE clips SET name = ? WHERE id = ?", arguments: [value, clipID])
            }
            if case .set(let value) = notes {
                let merged = baselineNotes.map {
                    ReviewNotesMerge.merge(draft: value ?? "", baseline: $0, current: current.notes ?? "")
                } ?? value
                try db.execute(sql: "UPDATE clips SET notes = ? WHERE id = ?", arguments: [merged, clipID])
            }
            guard let saved = try Clip.fetchOne(db, key: clipID) else { throw MarkerError.clipNotFound(clipID) }
            return saved
        }
        didChange()
        return saved
    }

    private func updateText(_ clipID: Int64, column: String, value: String?) throws {
        try database.write { db in
            guard try Clip.fetchOne(db, key: clipID) != nil else { throw MarkerError.clipNotFound(clipID) }
            try db.execute(sql: "UPDATE clips SET \(column) = ? WHERE id = ?", arguments: [value, clipID])
        }
        didChange()
    }

    func updateMood(_ clipID: Int64, mood: String?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET mood = ? WHERE id = ?",
                arguments: [mood, clipID]
            )
        }
        didChange()
    }

    func updateStructured(
        _ clipID: Int64,
        shotType: FieldUpdate<String> = .unchanged,
        cameraMove: FieldUpdate<String> = .unchanged,
        setting: FieldUpdate<String> = .unchanged
    ) throws {
        try database.write { db in
            if case .set(let shotType) = shotType {
                try db.execute(sql: "UPDATE clips SET shot_type = ? WHERE id = ?",
                               arguments: [shotType, clipID])
            }
            if case .set(let cameraMove) = cameraMove {
                try db.execute(sql: "UPDATE clips SET camera_move = ? WHERE id = ?",
                               arguments: [cameraMove, clipID])
            }
            if case .set(let setting) = setting {
                try db.execute(sql: "UPDATE clips SET setting = ? WHERE id = ?",
                               arguments: [setting, clipID])
            }
        }
        didChange()
    }

    /// Set (or clear, with nil) a clip's CSV purpose field wholesale.
    func updatePurpose(_ clipID: Int64, purpose: String?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET purpose = ? WHERE id = ?",
                arguments: [purpose, clipID]
            )
        }
        didChange()
    }

    /// Toggle a single purpose key in a clip's CSV set, normalizing to nil when
    /// the last key is removed. Keeps key order stable for the others.
    @discardableResult
    func togglePurpose(_ clipID: Int64, key: String) throws -> [String] {
        let keys = try database.write { db in
            guard let clip = try Clip.fetchOne(db, key: clipID) else { throw MarkerError.clipNotFound(clipID) }
            var keys = clip.purposeList
            if let idx = keys.firstIndex(of: key) { keys.remove(at: idx) }
            else { keys.append(key) }
            try db.execute(sql: "UPDATE clips SET purpose = ? WHERE id = ?",
                           arguments: [keys.isEmpty ? nil : keys.joined(separator: ","), clipID])
            return keys
        }
        didChange()
        return keys
    }

    /// How many clips have been marked from a given source. Drives the session
    /// rail's per-source clip count.
    func clipCount(forSource sourceID: Int64) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE source_id = ?",
                arguments: [sourceID]
            ) ?? 0
        }
    }

    /// Mark a source reviewed (stamps `reviewed_at` now) or clears the flag.
    func markSourceReviewed(_ sourceID: Int64, reviewed: Bool) throws {
        let ts: Int64? = reviewed ? Int64(Date().timeIntervalSince1970) : nil
        try database.write { db in
            try db.execute(
                sql: "UPDATE sources SET reviewed_at = ? WHERE id = ?",
                arguments: [ts, sourceID]
            )
        }
        didChange()
    }

    func deleteClip(_ clipID: Int64) throws {
        _ = try deleteClips([clipID])
    }

    /// Capture and delete as one transaction. Undo retains the original identity,
    /// every clip field, group membership, tags, and export-history linkage.
    func deleteClips(_ clipIDs: Set<Int64>) throws -> [DeletedClip] {
        let snapshots = try database.write { db in
            try clipIDs.sorted().map { id -> DeletedClip in
                guard let clip = try Clip.fetchOne(db, key: id) else { throw MarkerError.clipNotFound(id) }
                let snapshot = DeletedClip(
                    clip: clip,
                    tags: try Tag.fetchAll(db, sql: "SELECT t.* FROM tags t JOIN clip_tags ct ON ct.tag_id = t.id WHERE ct.clip_id = ?", arguments: [id]),
                    projectIDs: try Int64.fetchAll(db, sql: "SELECT project_id FROM clip_projects WHERE clip_id = ?", arguments: [id]),
                    collectionIDs: try Int64.fetchAll(db, sql: "SELECT collection_id FROM clip_collections WHERE clip_id = ?", arguments: [id]),
                    exportIDs: try Int64.fetchAll(db, sql: "SELECT id FROM exports WHERE clip_id = ?", arguments: [id])
                )
                try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
                return snapshot
            }
        }
        didChange()
        return snapshots
    }

    func restore(_ snapshots: [DeletedClip]) throws {
        try database.write { db in
            for snapshot in snapshots {
                var clip = snapshot.clip
                guard let id = clip.id else { continue }
                try Self.validateRange(db, sourceID: clip.sourceID, inMs: clip.inMs, outMs: clip.outMs)
                try clip.insert(db)
                for tag in snapshot.tags { try TagStore.addTag(tag.name, toClip: id, in: db) }
                for pid in snapshot.projectIDs {
                    try db.execute(sql: "INSERT INTO clip_projects(clip_id, project_id) SELECT ?, id FROM projects WHERE id = ?", arguments: [id, pid])
                }
                for cid in snapshot.collectionIDs {
                    try db.execute(sql: "INSERT INTO clip_collections(clip_id, collection_id) SELECT ?, id FROM collections WHERE id = ?", arguments: [id, cid])
                }
                for exportID in snapshot.exportIDs {
                    try db.execute(sql: "UPDATE exports SET clip_id = ? WHERE id = ? AND clip_id IS NULL", arguments: [id, exportID])
                }
            }
        }
        didChange()
    }

    func fetchClips(forSource sourceID: Int64) throws -> [Clip] {
        try database.read { db in
            try Clip.filter(Clip.Columns.sourceID == sourceID)
                .order(Clip.Columns.inMs.asc)
                .fetchAll(db)
        }
    }

    func fetchClip(_ id: Int64) throws -> Clip? {
        try database.read { db in
            try Clip.fetchOne(db, key: id)
        }
    }

    func incrementUsed(_ clipID: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET used_count = used_count + 1 WHERE id = ?",
                arguments: [clipID]
            )
        }
        // Was previously the only mutation in this file that didn't bump —
        // usage badges in the library grid never refreshed after export.
        didChange()
    }
}

enum MarkerError: LocalizedError {
    case invalidRange(inMs: Int64, outMs: Int64)
    case sourceNotFound(Int64)
    case clipNotFound(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidRange(let i, let o):
            return "Invalid clip range (in=\(i)ms out=\(o)ms). Choose a range within the source, with Out after In."
        case .sourceNotFound(let id):
            return "Source #\(id) not found"
        case .clipNotFound(let id):
            return "Clip #\(id) not found"
        }
    }
}

enum FieldUpdate<Value> {
    case unchanged
    case set(Value?)
}

struct DeletedClip {
    let clip: Clip
    let tags: [Tag]
    let projectIDs: [Int64]
    let collectionIDs: [Int64]
    let exportIDs: [Int64]
}
