import Foundation
import GRDB

/// FTS5-backed search across clips, plus structured filter compilation.
final class SearchEngine {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Rebuilds the external-content FTS index from the clips table — recovers
    /// from any desync (interrupted migration, out-of-band mutation). (#25)
    func rebuildIndex() throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }
    }

    /// Runs the FTS5 integrity check; false if the index is desynced. (#25)
    func isIndexHealthy() -> Bool {
        do {
            try database.write { db in
                try db.execute(sql: "INSERT INTO clips_fts(clips_fts, rank) VALUES('integrity-check', 1)")
            }
            return true
        } catch {
            return false
        }
    }

    /// Launch-time maintenance: verify the index and rebuild it if it fails. (#25)
    func verifyAndRepairIndex() {
        if !isIndexHealthy() {
            ClipxLog.library.error("FTS index failed integrity check — rebuilding")
            try? rebuildIndex()
        }
    }

    /// Returns clip IDs matching the free-text query (FTS5) intersected with
    /// the given filters. Sorted by the provided sort option.
    ///
    /// Query syntax: leading `:` enables raw FTS5 (quoted phrases,
    /// AND/OR/NOT operators) so power users aren't trapped by the default
    /// prefix-token mode. Plain queries get every token prefix-matched.
    func search(
        query: String,
        filters: ClipFilters,
        sort: ClipSortOption,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Clip] {
        try database.read { db in
            // Join the source so "filmed" sorts can order by the source's
            // recording date, not the clip's marker-creation time. (#23)
            var sql = "SELECT c.* FROM clips c JOIN sources s ON s.id = c.source_id"
            var arguments: [DatabaseValueConvertible] = []
            var wheres: [String] = []

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                if trimmedQuery.hasPrefix(":") {
                    wheres.append("c.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
                    arguments.append(SearchEngine.compileFTS(trimmedQuery))
                } else {
                    // A clip must match every token, but each token can come
                    // from its text or its tags. Subqueries keep MATCH in an
                    // FTS scan and avoid duplicate clips for multiple tags.
                    for token in trimmedQuery.split(whereSeparator: \.isWhitespace) {
                        wheres.append("""
                            (c.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)
                             OR EXISTS (SELECT 1 FROM clip_tags ct JOIN tags t ON t.id = ct.tag_id
                                        WHERE ct.clip_id = c.id AND t.name LIKE ? ESCAPE '\\'))
                            """)
                        arguments.append(SearchEngine.escapeFTS(String(token)))
                        arguments.append("%\(sqlLikeEscape(token.lowercased()))%")
                    }
                }
            }

            if filters.minRating > 0 {
                wheres.append("c.rating >= ?")
                arguments.append(filters.minRating)
            }
            if !filters.colorLabels.isEmpty {
                let placeholders = filters.colorLabels.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.color_label IN (\(placeholders))")
                arguments.append(contentsOf: filters.colorLabels.map { $0 as DatabaseValueConvertible })
            }
            if !filters.shotTypes.isEmpty {
                let placeholders = filters.shotTypes.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.shot_type IN (\(placeholders))")
                arguments.append(contentsOf: filters.shotTypes.map { $0 as DatabaseValueConvertible })
            }
            if !filters.cameraMoves.isEmpty {
                let placeholders = filters.cameraMoves.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.camera_move IN (\(placeholders))")
                arguments.append(contentsOf: filters.cameraMoves.map { $0 as DatabaseValueConvertible })
            }
            if !filters.settings.isEmpty {
                let placeholders = filters.settings.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.setting IN (\(placeholders))")
                arguments.append(contentsOf: filters.settings.map { $0 as DatabaseValueConvertible })
            }
            if !filters.moods.isEmpty {
                // ESCAPE clause — user-typed moods could contain `%`/`_`
                // which previously matched arbitrary text.
                let likes = filters.moods.map { _ in "c.mood LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
                wheres.append("(\(likes))")
                arguments.append(contentsOf: filters.moods.map { "%\(sqlLikeEscape($0))%" as DatabaseValueConvertible })
            }
            if filters.unusedOnly {
                wheres.append("c.used_count = 0")
            }
            if !filters.projectIDs.isEmpty {
                let placeholders = filters.projectIDs.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.id IN (SELECT clip_id FROM clip_projects WHERE project_id IN (\(placeholders)))")
                arguments.append(contentsOf: filters.projectIDs.map { $0 as DatabaseValueConvertible })
            }
            if !filters.collectionIDs.isEmpty {
                let placeholders = filters.collectionIDs.map { _ in "?" }.joined(separator: ",")
                wheres.append("c.id IN (SELECT clip_id FROM clip_collections WHERE collection_id IN (\(placeholders)))")
                arguments.append(contentsOf: filters.collectionIDs.map { $0 as DatabaseValueConvertible })
            }

            let dateColumn = filters.dateField == .imported ? "s.imported_at" : "COALESCE(s.created_at, s.imported_at)"
            if let from = filters.dateFrom {
                wheres.append("\(dateColumn) >= ?")
                arguments.append(from.timeIntervalSince1970)
            }
            if let to = filters.dateTo {
                wheres.append("\(dateColumn) <= ?")
                arguments.append(to.timeIntervalSince1970)
            }
            if filters.onlineOnly { wheres.append("s.online = 1") }

            if !wheres.isEmpty {
                sql += " WHERE " + wheres.joined(separator: " AND ")
            }
            sql += " ORDER BY \(SearchEngine.orderBy(sort)), c.id ASC LIMIT ? OFFSET ?"
            arguments.append(limit.map { max(0, $0) } ?? -1)
            arguments.append(max(0, offset))

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Compiles user input into an FTS5 MATCH expression. If the user starts
    /// with `:` the rest is treated as raw FTS5 (so they can write
    /// `"exact phrase"` or `wide AND outdoor`). Otherwise we tokenize and
    /// prefix-match each token.
    static func compileFTS(_ raw: String) -> String {
        if raw.hasPrefix(":") {
            return String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return escapeFTS(raw)
    }

    /// Legacy public escape entrypoint (kept for tests). Same behavior as
    /// the non-raw path in `compileFTS`.
    static func escapeFTS(_ raw: String) -> String {
        let tokens = raw
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        return tokens.joined(separator: " ")
    }

    private static func orderBy(_ sort: ClipSortOption) -> String {
        // "Filmed" date = the source's recording date (falling back to its
        // import time), with in-point as a stable tiebreak within a source. The
        // bug (#23) was using c.created_at, which is when the clip was *marked*.
        let filmedDesc = "COALESCE(s.created_at, s.imported_at) DESC, c.in_ms ASC"
        let filmedAsc  = "COALESCE(s.created_at, s.imported_at) ASC, c.in_ms ASC"
        switch sort {
        case .sourceDateDesc, .dateImportedDesc:
            return filmedDesc
        case .sourceDateAsc, .dateImportedAsc:
            return filmedAsc
        // "Recently / first imported" legitimately tracks when the clip was
        // added (marked) — clips have no separate import timestamp.
        case .importedDesc: return "s.imported_at DESC"
        case .importedAsc:  return "s.imported_at ASC"
        case .ratingDesc:   return "c.rating DESC, " + filmedDesc
        case .durationDesc: return "(c.out_ms - c.in_ms) DESC"
        case .nameAsc:      return "c.name ASC"
        }
    }
    func searchSources(query: String, filters: ClipFilters, sort: ClipSortOption,
                       limit: Int? = nil, offset: Int = 0) throws -> [Source] {
        let (whereSQL, args) = Self.sourcesWhere(query: query, filters: filters)
        var arguments = args
        arguments.append(limit.map { max(0, $0) } ?? -1)
        arguments.append(max(0, offset))
        return try database.read { db in
            try Source.fetchAll(db, sql: "SELECT * FROM sources \(whereSQL) ORDER BY \(Self.sourcesOrderBy(sort)), id ASC LIMIT ? OFFSET ?",
                                arguments: StatementArguments(arguments))
        }
    }

    static func sourcesWhere(query: String, filters: ClipFilters) -> (String, [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            clauses.append("LOWER(path) LIKE ? ESCAPE '\\'")
            args.append("%\(sqlLikeEscape(q.lowercased()))%")
        }
        if let from = filters.dateFrom {
            clauses.append("\(filters.dateField == .imported ? "imported_at" : "COALESCE(created_at, imported_at)") >= ?")
            args.append(from.timeIntervalSince1970)
        }
        if let to = filters.dateTo {
            clauses.append("\(filters.dateField == .imported ? "imported_at" : "COALESCE(created_at, imported_at)") <= ?")
            args.append(to.timeIntervalSince1970)
        }
        if filters.onlineOnly { clauses.append("online = 1") }
        // Clip-attribute filters can't match whole sources; when one is active
        // hide sources so the view focuses on the matching clips.
        let clipOnly = !filters.moods.isEmpty || !filters.shotTypes.isEmpty
            || !filters.cameraMoves.isEmpty || !filters.settings.isEmpty
            || !filters.colorLabels.isEmpty || filters.minRating > 0 || filters.unusedOnly
            || !filters.projectIDs.isEmpty || !filters.collectionIDs.isEmpty
        if clipOnly { clauses.append("1 = 0") }
        let sql = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (sql, args)
    }

    /// Maps the user-selected sort option into a SQL ORDER BY clause for the
    /// sources table. "Newest / Oldest" uses the source's own recording date
    /// (`created_at`, pulled from file metadata) instead of the import date —
    /// you want to find the day you shot it, not the day you imported it.
    /// Imported-at is used as a fallback for sources whose metadata didn't
    /// produce a creation date.
    static func sourcesOrderBy(_ sort: ClipSortOption) -> String {
        switch sort {
        case .sourceDateDesc, .dateImportedDesc:
            return "COALESCE(created_at, imported_at) DESC"
        case .sourceDateAsc, .dateImportedAsc:
            return "COALESCE(created_at, imported_at) ASC"
        case .importedDesc:
            return "imported_at DESC"
        case .importedAsc:
            return "imported_at ASC"
        case .durationDesc:
            return "COALESCE(duration_ms, 0) DESC"
        case .nameAsc:
            return "LOWER(path) ASC"
        case .ratingDesc:
            return "COALESCE(created_at, imported_at) DESC" // sources have no rating
        }
    }

}
