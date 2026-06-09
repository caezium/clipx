import Foundation
import GRDB

/// FTS5-backed search across clips, plus structured filter compilation.
final class SearchEngine {
    private let database: Database

    init(database: Database) {
        self.database = database
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
        limit: Int = 500
    ) throws -> [Clip] {
        try database.read { db in
            // Join the source so "filmed" sorts can order by the source's
            // recording date, not the clip's marker-creation time. (#23)
            var sql = "SELECT c.* FROM clips c JOIN sources s ON s.id = c.source_id"
            var arguments: [DatabaseValueConvertible] = []
            var wheres: [String] = []

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                sql += " JOIN clips_fts ON clips_fts.rowid = c.id"
                wheres.append("clips_fts MATCH ?")
                arguments.append(SearchEngine.compileFTS(trimmedQuery))
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

            if !wheres.isEmpty {
                sql += " WHERE " + wheres.joined(separator: " AND ")
            }
            sql += " ORDER BY \(SearchEngine.orderBy(sort)) LIMIT ?"
            arguments.append(limit)

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
        case .importedDesc: return "c.created_at DESC"
        case .importedAsc:  return "c.created_at ASC"
        case .ratingDesc:   return "c.rating DESC, " + filmedDesc
        case .durationDesc: return "(c.out_ms - c.in_ms) DESC"
        case .nameAsc:      return "c.name ASC"
        }
    }
}
