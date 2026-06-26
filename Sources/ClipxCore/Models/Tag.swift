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
