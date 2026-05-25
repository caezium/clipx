import Foundation
import GRDB

/// CRUD on tags and clip↔tag relationships. Provides autocomplete for tag UIs.
final class TagStore {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Ensures a tag exists; returns its id.
    ///
    /// Atomic via `INSERT … ON CONFLICT(name) DO UPDATE … RETURNING id`. The
    /// previous "SELECT then INSERT" sequence had a tiny race window across
    /// concurrent writers (GRDB serializes writes but two adjacent
    /// upsertTag calls would each see "no row" before the other inserted).
    @discardableResult
    func upsertTag(name: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw TagError.empty }
        return try database.write { db -> Int64 in
            let row = try Row.fetchOne(
                db,
                sql: """
                    INSERT INTO tags(name) VALUES (?)
                    ON CONFLICT(name) DO UPDATE SET name = excluded.name
                    RETURNING id
                """,
                arguments: [trimmed]
            )
            return row?["id"] ?? db.lastInsertedRowID
        }
    }

    func addTag(_ tagName: String, toClip clipID: Int64) throws {
        let tagID = try upsertTag(name: tagName)
        try database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO clip_tags(clip_id, tag_id) VALUES (?, ?)",
                arguments: [clipID, tagID]
            )
        }
    }

    func removeTag(_ tagName: String, fromClip clipID: Int64) throws {
        let lower = tagName.lowercased()
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM clip_tags
                WHERE clip_id = ? AND tag_id IN (SELECT id FROM tags WHERE name = ?)
            """, arguments: [clipID, lower])
        }
    }

    func tags(forClip clipID: Int64) throws -> [Tag] {
        try database.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT t.* FROM tags t
                JOIN clip_tags ct ON ct.tag_id = t.id
                WHERE ct.clip_id = ?
                ORDER BY t.name
            """, arguments: [clipID])
        }
    }

    func suggestions(prefix: String, limit: Int = 10) throws -> [Tag] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return try database.read { db in
                try Tag.order(Tag.Columns.name).limit(limit).fetchAll(db)
            }
        }
        // Escape `%` / `_` so a tag prefix like "100%" doesn't match arbitrary chars.
        let escaped = sqlLikeEscape(needle)
        return try database.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT * FROM tags WHERE name LIKE ? ESCAPE '\\' ORDER BY name LIMIT ?
            """, arguments: ["\(escaped)%", limit])
        }
    }
}

enum TagError: LocalizedError {
    case empty
    var errorDescription: String? {
        switch self {
        case .empty: return "Tag name is empty"
        }
    }
}
