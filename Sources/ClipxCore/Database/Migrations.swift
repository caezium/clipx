import Foundation
import GRDB

/// Versioned schema migrations. Add new migrations at the bottom; never edit
/// or remove existing ones — GRDB tracks applied versions per migration name.
enum Migrations {
    static func register() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).unique().notNull()
                t.column("bookmark", .blob)
                t.column("hash", .text).notNull()
                t.column("mtime", .integer).notNull()
                t.column("duration_ms", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("fps", .double)
                t.column("codec", .text)
                t.column("audio_channels", .integer)
                t.column("color_space", .text)
                t.column("created_at", .integer)
                t.column("imported_at", .integer).notNull()
                t.column("thumb_path", .text)
                t.column("online", .integer).notNull().defaults(to: 1)
                t.column("notes", .text)
            }
            try db.create(index: "idx_sources_hash", on: "sources", columns: ["hash"])
            try db.create(index: "idx_sources_imported_at", on: "sources", columns: ["imported_at"])

            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().references("sources", onDelete: .cascade)
                t.column("name", .text)
                t.column("in_ms", .integer).notNull()
                t.column("out_ms", .integer).notNull()
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("color_label", .integer)
                t.column("mood", .text)
                t.column("shot_type", .text)
                t.column("camera_move", .text)
                t.column("setting", .text)
                t.column("notes", .text)
                t.column("created_at", .integer).notNull()
                t.column("used_count", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_clips_source", on: "clips", columns: ["source_id"])
            try db.create(index: "idx_clips_rating", on: "clips", columns: ["rating"])
            try db.create(index: "idx_clips_color", on: "clips", columns: ["color_label"])

            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).unique().notNull()
            }
            try db.create(table: "clip_tags") { t in
                t.column("clip_id", .integer).notNull().references("clips", onDelete: .cascade)
                t.column("tag_id", .integer).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["clip_id", "tag_id"])
            }

            try db.create(table: "collections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "clip_collections") { t in
                t.column("clip_id", .integer).notNull().references("clips", onDelete: .cascade)
                t.column("collection_id", .integer).notNull().references("collections", onDelete: .cascade)
                t.primaryKey(["clip_id", "collection_id"])
            }

            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("status", .text)
                t.column("obsidian_note_path", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "clip_projects") { t in
                t.column("clip_id", .integer).notNull().references("clips", onDelete: .cascade)
                t.column("project_id", .integer).notNull().references("projects", onDelete: .cascade)
                t.primaryKey(["clip_id", "project_id"])
            }

            try db.create(table: "exports") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clip_id", .integer).references("clips", onDelete: .setNull)
                t.column("preset", .text).notNull()
                t.column("output_path", .text)
                t.column("bytes", .integer)
                t.column("duration_ms", .integer)
                t.column("exported_at", .integer).notNull()
                t.column("status", .text).notNull()
            }

            try db.create(table: "folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).unique().notNull()
                t.column("bookmark", .blob).notNull()
                t.column("added_at", .integer).notNull()
                t.column("last_scan_at", .integer)
                t.column("online", .integer).notNull().defaults(to: 1)
            }

            // FTS5 virtual table for instant clip search.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    name, notes, mood, shot_type, content='clips', content_rowid='id'
                );
            """)
            // Triggers keep FTS in sync with clips.
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, name, notes, mood, shot_type)
                    VALUES (new.id, new.name, new.notes, new.mood, new.shot_type);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, name, notes, mood, shot_type)
                    VALUES ('delete', old.id, old.name, old.notes, old.mood, old.shot_type);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, name, notes, mood, shot_type)
                    VALUES ('delete', old.id, old.name, old.notes, old.mood, old.shot_type);
                    INSERT INTO clips_fts(rowid, name, notes, mood, shot_type)
                    VALUES (new.id, new.name, new.notes, new.mood, new.shot_type);
                END;
            """)
        }

        return migrator
    }
}
