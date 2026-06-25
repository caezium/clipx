import Foundation
import GRDB

/// Thin wrapper around a GRDB `DatabaseWriter` that owns schema migrations
/// and provides a single point of construction for the app database.
///
/// Backed by a `DatabasePool` on disk so UI reads (per-card thumbnail lookups,
/// the library reload) run concurrently with indexer writes instead of
/// serializing behind them — the previous `DatabaseQueue` funneled every
/// access through one connection, so a scroll-time read could stall behind a
/// watcher write. WAL (already enabled below) is what makes the pool's
/// concurrent readers safe. Tests still use an in-memory `DatabaseQueue`.
final class Database {
    let dbWriter: any DatabaseWriter

    private init(writer: any DatabaseWriter) {
        self.dbWriter = writer
    }

    /// Opens (or creates) the app database at the canonical Application Support
    /// path, recovering from corruption instead of blocking launch. (#24)
    static func open() throws -> Database {
        let url = try defaultDatabaseURL()
        let db = try openOrRecover(at: url)
        db.writeBackup(of: url)   // rolling backup after a known-good open
        return db
    }

    /// Opens + migrates the database at `url`, and on failure (corruption /
    /// failed integrity check) preserves the bad file aside and starts fresh —
    /// rather than crashing every launch with no recourse but data loss. (#24)
    static func openOrRecover(at url: URL) throws -> Database {
        do {
            return try openMigrating(at: url)
        } catch {
            ClipxLog.app.error("DB open failed, recovering: \(String(describing: error), privacy: .public)")
            // Prefer restoring the most recent backup over an empty library.
            let backup = url.deletingLastPathComponent().appendingPathComponent("clipx.backup.sqlite")
            sidelineCorruptFile(at: url)
            if FileManager.default.fileExists(atPath: backup.path),
               (try? FileManager.default.copyItem(at: backup, to: url)) != nil,
               let restored = try? openMigrating(at: url) {
                return restored
            }
            return try openMigrating(at: url)   // last resort: fresh DB
        }
    }

    private static func openMigrating(at url: URL) throws -> Database {
        var config = Configuration()
        config.label = "clipx.db"
        config.foreignKeysEnabled = true
        // Busy timeout avoids SQLITE_BUSY when the watcher fires while the user
        // is searching. (WAL itself is enabled by DatabasePool automatically —
        // re-asserting `journal_mode = WAL` here would run on the pool's
        // read-only reader connections too, so we leave it to GRDB and only
        // tune synchronous, which is safe to set per-connection.)
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        // DatabasePool keeps a pool of reader connections alongside the single
        // writer, so reads run concurrently with writes under WAL.
        let pool = try DatabasePool(path: url.path, configuration: config)
        // Catch corruption before migrating into a damaged page set. (#24)
        try pool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            if result != "ok" {
                throw NSError(domain: "clipx.db", code: -100,
                              userInfo: [NSLocalizedDescriptionKey: "integrity_check: \(result ?? "nil")"])
            }
        }
        try Migrations.register().migrate(pool)
        return Database(writer: pool)
    }

    /// Move a corrupt DB (and its WAL/SHM siblings) aside, timestamped, so the
    /// user's data is preserved for manual recovery rather than destroyed. (#24)
    private static func sidelineCorruptFile(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let asidePath = url.deletingLastPathComponent()
            .appendingPathComponent("clipx.corrupt-\(stamp).sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            let src = url.path + suffix
            if fm.fileExists(atPath: src) { try? fm.moveItem(atPath: src, toPath: asidePath + suffix) }
        }
    }

    /// Best-effort rolling backup of the (small) metadata DB so corruption has
    /// a recent restore point. (#24)
    func writeBackup(of url: URL) {
        let dest = url.deletingLastPathComponent().appendingPathComponent("clipx.backup.sqlite")
        do {
            let target = try DatabaseQueue(path: dest.path)
            try dbWriter.backup(to: target)
        } catch {
            ClipxLog.app.debug("DB backup skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// In-memory database for tests. Uses a `DatabaseQueue` — DatabasePool
    /// requires an on-disk WAL file, and tests want isolation, not concurrency.
    static func inMemory() throws -> Database {
        let queue = try DatabaseQueue()
        try Migrations.register().migrate(queue)
        return Database(writer: queue)
    }

    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let clipxDir = appSupport.appendingPathComponent("Clipx", isDirectory: true)
        if !fm.fileExists(atPath: clipxDir.path) {
            try fm.createDirectory(at: clipxDir, withIntermediateDirectories: true)
        }
        return clipxDir.appendingPathComponent("clipx.sqlite")
    }

    // MARK: Convenience

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }
}

/// Escapes `_` and `%` (and the escape char itself) for safe use inside a
/// SQL `LIKE` pattern. Use with `ESCAPE '\\'` in the query.
///
/// Bug: without this, a folder path containing `_` (very common — every
/// `My_Folder` or `2025_05_24`) matches one extra character per `_`, so
/// `markFolderOffline("/Users/x/My_Footage")` also flagged neighbours.
public func sqlLikeEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "\\": out.append("\\\\")
        case "%":  out.append("\\%")
        case "_":  out.append("\\_")
        default:   out.append(c)
        }
    }
    return out
}
