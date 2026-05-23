import Foundation
import GRDB

/// A source video file on disk. Sources are non-mutating; the file itself
/// is never modified. Clips are non-destructive ranges that reference a source.
struct Source: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var path: String
    var bookmark: Data?
    var hash: String
    var mtime: Int64
    var durationMs: Int64?
    var width: Int?
    var height: Int?
    var fps: Double?
    var codec: String?
    var audioChannels: Int?
    var colorSpace: String?
    var createdAt: Int64?
    var importedAt: Int64
    var thumbPath: String?
    var online: Bool = true
    var notes: String?

    static let databaseTableName = "sources"

    enum CodingKeys: String, CodingKey {
        case id, path, bookmark, hash, mtime
        case durationMs = "duration_ms"
        case width, height, fps, codec
        case audioChannels = "audio_channels"
        case colorSpace = "color_space"
        case createdAt = "created_at"
        case importedAt = "imported_at"
        case thumbPath = "thumb_path"
        case online, notes
    }

    enum Columns: String, ColumnExpression {
        case id, path, bookmark, hash, mtime
        case durationMs = "duration_ms"
        case width, height, fps, codec
        case audioChannels = "audio_channels"
        case colorSpace = "color_space"
        case createdAt = "created_at"
        case importedAt = "imported_at"
        case thumbPath = "thumb_path"
        case online, notes
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var resolutionLabel: String {
        guard let w = width, let h = height else { return "unknown" }
        switch (w, h) {
        case (3840, 2160), (4096, 2160): return "4K"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        case (1080, 1920): return "1080p (vert)"
        default: return "\(w)×\(h)"
        }
    }

    var aspectRatio: Double? {
        guard let w = width, let h = height, h > 0 else { return nil }
        return Double(w) / Double(h)
    }
}
