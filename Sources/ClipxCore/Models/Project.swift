import Foundation
import GRDB

/// Optional grouping of clips destined for a specific output video.
struct Project: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var status: String = ProjectStatus.planning.rawValue
    var obsidianNotePath: String?
    var createdAt: Int64

    static let databaseTableName = "projects"

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case obsidianNotePath = "obsidian_note_path"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, name, status
        case obsidianNotePath = "obsidian_note_path"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ProjectStatus: String, CaseIterable {
    case planning, editing, published, archived

    var label: String { rawValue.capitalized }
}
