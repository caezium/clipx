import Foundation
import GRDB

/// CRUD on the clips table. Marker semantics live here so the UI and the
/// keyboard-shortcut layer share the same validation.
final class MarkerStore {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Saves a new clip range. Returns the inserted clip with its id populated.
    @discardableResult
    func saveRange(sourceID: Int64, inMs: Int64, outMs: Int64, name: String? = nil) throws -> Clip {
        guard outMs > inMs else {
            throw MarkerError.invalidRange(inMs: inMs, outMs: outMs)
        }
        var clip = Clip(
            id: nil,
            sourceID: sourceID,
            name: name,
            inMs: inMs,
            outMs: outMs,
            rating: 0,
            colorLabel: nil,
            mood: nil,
            shotType: nil,
            cameraMove: nil,
            setting: nil,
            notes: nil,
            createdAt: Int64(Date().timeIntervalSince1970),
            usedCount: 0
        )
        try database.write { db in
            try clip.insert(db)
        }
        Self.bumpRevision()
        return clip
    }

    func updateRating(_ clipID: Int64, rating: Int) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET rating = ? WHERE id = ?",
                arguments: [max(0, min(5, rating)), clipID]
            )
        }
        Self.bumpRevision()
    }

    func updateColorLabel(_ clipID: Int64, label: Int?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET color_label = ? WHERE id = ?",
                arguments: [label, clipID]
            )
        }
        Self.bumpRevision()
    }

    func updateRange(_ clipID: Int64, inMs: Int64, outMs: Int64) throws {
        guard outMs > inMs else {
            throw MarkerError.invalidRange(inMs: inMs, outMs: outMs)
        }
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET in_ms = ?, out_ms = ? WHERE id = ?",
                arguments: [inMs, outMs, clipID]
            )
        }
        Self.bumpRevision()
    }

    /// Notify SwiftUI views that the clips table changed. Centralized so every
    /// mutating call site stays in sync.
    private static func bumpRevision() {
        Task { @MainActor in
            AppState.shared.libraryRevision &+= 1
        }
    }

    func updateMood(_ clipID: Int64, mood: String?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET mood = ? WHERE id = ?",
                arguments: [mood, clipID]
            )
        }
        Self.bumpRevision()
    }

    func updateStructured(
        _ clipID: Int64,
        shotType: String? = nil,
        cameraMove: String? = nil,
        setting: String? = nil
    ) throws {
        try database.write { db in
            if let shotType = shotType {
                try db.execute(sql: "UPDATE clips SET shot_type = ? WHERE id = ?",
                               arguments: [shotType, clipID])
            }
            if let cameraMove = cameraMove {
                try db.execute(sql: "UPDATE clips SET camera_move = ? WHERE id = ?",
                               arguments: [cameraMove, clipID])
            }
            if let setting = setting {
                try db.execute(sql: "UPDATE clips SET setting = ? WHERE id = ?",
                               arguments: [setting, clipID])
            }
        }
        Self.bumpRevision()
    }

    /// Set (or clear, with nil) a clip's CSV purpose field wholesale.
    func updatePurpose(_ clipID: Int64, purpose: String?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clips SET purpose = ? WHERE id = ?",
                arguments: [purpose, clipID]
            )
        }
        Self.bumpRevision()
    }

    /// Toggle a single purpose key in a clip's CSV set, normalizing to nil when
    /// the last key is removed. Keeps key order stable for the others.
    @discardableResult
    func togglePurpose(_ clipID: Int64, key: String) throws -> [String] {
        var keys = (try fetchClip(clipID))?.purposeList ?? []
        if let idx = keys.firstIndex(of: key) {
            keys.remove(at: idx)
        } else {
            keys.append(key)
        }
        try updatePurpose(clipID, purpose: keys.isEmpty ? nil : keys.joined(separator: ","))
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
        Self.bumpRevision()
    }

    func deleteClip(_ clipID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [clipID])
        }
        Self.bumpRevision()
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
        Self.bumpRevision()
    }
}

enum MarkerError: LocalizedError {
    case invalidRange(inMs: Int64, outMs: Int64)
    case sourceNotFound(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidRange(let i, let o):
            return "Invalid clip range (in=\(i)ms out=\(o)ms): out must be greater than in"
        case .sourceNotFound(let id):
            return "Source #\(id) not found"
        }
    }
}
