import Foundation
import GRDB

/// A user-selected root folder being watched. Holds the security-scoped
/// bookmark so we can resume access after relaunch.
struct FolderRecord: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var path: String
    var bookmark: Data
    var addedAt: Int64
    var lastScanAt: Int64?
    var online: Bool = true

    static let databaseTableName = "folders"

    enum CodingKeys: String, CodingKey {
        case id, path, bookmark
        case addedAt = "added_at"
        case lastScanAt = "last_scan_at"
        case online
    }

    enum Columns: String, ColumnExpression {
        case id, path, bookmark
        case addedAt = "added_at"
        case lastScanAt = "last_scan_at"
        case online
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
