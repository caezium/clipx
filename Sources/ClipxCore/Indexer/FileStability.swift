import Foundation

/// Stability gate for indexing. A file modified within the last few seconds may
/// be a copy still in progress; indexing it then captures a truncated hash,
/// wrong duration, and a thumbnail from a partial frame, which the skip-on-
/// unchanged-mtime logic would then never correct. Only index once the file has
/// stopped changing. (#20)
enum FileStability {
    static func isStable(mtimeEpoch: Int64, now: Int64, minAgeSeconds: Int64 = 3) -> Bool {
        now - mtimeEpoch >= minAgeSeconds
    }
}
