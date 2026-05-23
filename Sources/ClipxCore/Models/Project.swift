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

struct ClipProject: Codable, FetchableRecord, PersistableRecord {
    var clipID: Int64
    var projectID: Int64

    static let databaseTableName = "clip_projects"

    enum Columns: String, ColumnExpression {
        case clipID = "clip_id"
        case projectID = "project_id"
    }
}
