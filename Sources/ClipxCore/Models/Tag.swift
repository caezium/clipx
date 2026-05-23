import Foundation
import GRDB

struct Tag: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String

    static let databaseTableName = "tags"

    enum Columns: String, ColumnExpression { case id, name }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ClipTag: Codable, FetchableRecord, PersistableRecord {
    var clipID: Int64
    var tagID: Int64

    static let databaseTableName = "clip_tags"

    enum Columns: String, ColumnExpression {
        case clipID = "clip_id"
        case tagID = "tag_id"
    }
}
