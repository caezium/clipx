import Foundation
import GRDB

/// Versioned schema migrations. Add new migrations at the bottom; never edit
/// or remove existing ones — GRDB tracks applied versions per migration name.
///
/// Note: `eraseDatabaseOnSchemaChange` was deliberately removed. It nukes the
/// user's library if a dev edits an existing migration — too dangerous to leave
/// on, even in DEBUG. To reset locally, delete `~/Library/Application Support/Clipx`.
enum Migrations {
    static func register() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

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

        // v2: add `size` column for change-detection, plus indexes on hot
        // sort/filter columns the review flagged. SQLite doesn't allow
        // ALTER TABLE ADD CHECK — status validation lives in app code.
        migrator.registerMigration("v2_indexes_and_size") { db in
            try db.alter(table: "sources") { t in
                t.add(column: "size", .integer)
            }

            try db.create(
                index: "idx_sources_created_at",
                on: "sources",
                columns: ["created_at"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_sources_online",
                on: "sources",
                columns: ["online"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_clips_created_at",
                on: "clips",
                columns: ["created_at"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_clips_used_count",
                on: "clips",
                columns: ["used_count"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_exports_clip",
                on: "exports",
                columns: ["clip_id"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_exports_exported_at",
                on: "exports",
                columns: ["exported_at"],
                ifNotExists: true
            )
        }

        // v3: per-source rotation (degrees clockwise, 0/90/180/270) applied to
        // the player preview and baked into exports.
        migrator.registerMigration("v3_source_rotation") { db in
            try db.alter(table: "sources") { t in
                t.add(column: "rotation", .integer).notNull().defaults(to: 0)
            }
        }

        // v4: general-purpose "purpose" labels per clip (CSV of purpose keys,
        // e.g. "coach,reel") replacing the film-school taxonomy on the fast
        // path, plus a per-source `reviewed_at` timestamp that powers the Cut
        // Room session rail's progress (reviewed / in-progress / not-seen).
        migrator.registerMigration("v4_purpose_and_review") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "purpose", .text)
            }
            try db.alter(table: "sources") { t in
                t.add(column: "reviewed_at", .integer)
            }
        }

        // v5: the public Stint review share link a clip was sent to (the
        // Clipx → Stint collaboration bridge), so the Light Table can show
        // "shared for review" and reopen the link.
        migrator.registerMigration("v5_stint_review_url") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "review_url", .text)
            }
        }

        // v6: full linkage so review comments can be pulled BACK from Stint —
        // the stint clip/project ids per clip, a cached comment count, and a
        // table holding each Stint project's owner key + base URL (needed for
        // owner-authenticated comment fetches).
        migrator.registerMigration("v6_stint_review_linkage") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "stint_clip_id", .text)
                t.add(column: "stint_project_id", .text)
                t.add(column: "review_comment_count", .integer)
            }
            try db.create(table: "stint_projects") { t in
                t.column("project_id", .text).primaryKey()
                t.column("owner_key", .text).notNull()
                t.column("share_token", .text).notNull()
                t.column("base_url", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
        }

        // v7: permanent per-source playback speed (e.g. 4× to play slow-mo
        // footage at normal speed), applied to the preview and baked into
        // exports. Defaults to 1.0 so existing sources are unchanged.
        migrator.registerMigration("v7_source_speed") { db in
            try db.alter(table: "sources") { t in
                t.add(column: "speed", .double).defaults(to: 1.0)
            }
        }

        migrator.registerMigration("v8_durable_review_transfers") { db in
            try db.create(table: "stint_transfer_batches") { t in
                t.column("id", .text).primaryKey()
                t.column("selection_key", .text).notNull()
                t.column("project_id", .text).notNull().references("stint_projects", column: "project_id")
                t.column("completed", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_stint_transfer_selection", on: "stint_transfer_batches", columns: ["selection_key", "completed"])
            try db.create(table: "stint_transfer_items") { t in
                t.column("batch_id", .text).notNull().references("stint_transfer_batches", column: "id", onDelete: .cascade)
                // Snapshot identity survives deletion and Undo of a local clip.
                t.column("clip_id", .integer).notNull()
                t.column("stint_clip_id", .text)
                t.column("uploaded", .integer).notNull().defaults(to: 0)
                t.primaryKey(["batch_id", "clip_id"])
            }
        }

        migrator.registerMigration("v9_validate_media_values") { db in
            try db.execute(sql: "UPDATE sources SET speed = 1 WHERE speed IS NULL OR speed <= 0 OR speed > 1000")
            // Existing records remain recoverable; reject new malformed ranges
            // even if a future caller bypasses MarkerStore.
            for operation in ["INSERT", "UPDATE OF in_ms, out_ms, source_id"] {
                let suffix = operation == "INSERT" ? "insert" : "update"
                try db.execute(sql: """
                    CREATE TRIGGER clips_valid_range_\(suffix) BEFORE \(operation) ON clips
                    WHEN new.in_ms < 0 OR new.out_ms <= new.in_ms
                    BEGIN SELECT RAISE(ABORT, 'Clip range must be positive and start at or after zero'); END;
                    """)
            }
            for operation in ["INSERT", "UPDATE OF speed"] {
                let suffix = operation == "INSERT" ? "insert" : "update"
                try db.execute(sql: """
                    CREATE TRIGGER sources_valid_speed_\(suffix) BEFORE \(operation) ON sources
                    WHEN new.speed IS NULL OR new.speed <= 0 OR new.speed > 1000
                    BEGIN SELECT RAISE(ABORT, 'Playback speed must be finite and positive'); END;
                    """)
            }
        }

        return migrator
    }
}
