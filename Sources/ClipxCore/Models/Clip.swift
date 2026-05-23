import Foundation
import GRDB

/// A non-destructive in/out range over a Source. Multiple clips may reference
/// the same source. The source file is never modified.
struct Clip: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var sourceID: Int64
    var name: String?
    var inMs: Int64
    var outMs: Int64
    var rating: Int = 0
    var colorLabel: Int?
    var mood: String?           // comma-separated multi-select
    var shotType: String?
    var cameraMove: String?
    var setting: String?
    var notes: String?
    var createdAt: Int64
    var usedCount: Int = 0

    static let databaseTableName = "clips"

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case name
        case inMs = "in_ms"
        case outMs = "out_ms"
        case rating
        case colorLabel = "color_label"
        case mood
        case shotType = "shot_type"
        case cameraMove = "camera_move"
        case setting
        case notes
        case createdAt = "created_at"
        case usedCount = "used_count"
    }

    enum Columns: String, ColumnExpression {
        case id
        case sourceID = "source_id"
        case name
        case inMs = "in_ms"
        case outMs = "out_ms"
        case rating
        case colorLabel = "color_label"
        case mood
        case shotType = "shot_type"
        case cameraMove = "camera_move"
        case setting
        case notes
        case createdAt = "created_at"
        case usedCount = "used_count"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var durationMs: Int64 { max(0, outMs - inMs) }

    var moodList: [String] {
        guard let mood, !mood.isEmpty else { return [] }
        return mood.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Finder-style color labels (0 = none).
enum ColorLabel: Int, CaseIterable {
    case none = 0, red = 1, orange = 2, yellow = 3, green = 4, blue = 5, purple = 6, gray = 7

    var displayName: String {
        switch self {
        case .none: return "None"
        case .red: return "Best"
        case .orange: return "Good"
        case .yellow: return "Maybe"
        case .green: return "Used"
        case .blue: return "B-roll"
        case .purple: return "Hero"
        case .gray: return "Archive"
        }
    }
}
