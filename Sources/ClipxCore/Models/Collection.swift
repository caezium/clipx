import Foundation
import GRDB

/// A user-curated bin of clips that lives across projects (FCP "Power Bin" model).
struct Collection: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var description: String?
    var createdAt: Int64

    static let databaseTableName = "collections"

    enum Columns: String, ColumnExpression {
        case id, name, description
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ClipCollection: Codable, FetchableRecord, PersistableRecord {
    var clipID: Int64
    var collectionID: Int64

    static let databaseTableName = "clip_collections"

    enum Columns: String, ColumnExpression {
        case clipID = "clip_id"
        case collectionID = "collection_id"
    }
}
