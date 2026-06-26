import Foundation
import GRDB

/// An audit-trail entry of an export run.
struct ExportRecord: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var clipID: Int64?
    var preset: String
    var outputPath: String?
    var bytes: Int64?
    var durationMs: Int64?
    var exportedAt: Int64
    var status: String

    static let databaseTableName = "exports"

    enum CodingKeys: String, CodingKey {
        case id
        case clipID = "clip_id"
        case preset
        case outputPath = "output_path"
        case bytes
        case durationMs = "duration_ms"
        case exportedAt = "exported_at"
        case status
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ExportStatus: String { case success, failed, cancelled, inProgress = "in_progress" }
