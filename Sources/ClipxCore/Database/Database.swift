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
    let recoveryMessage: String?

    private init(writer: any DatabaseWriter, recoveryMessage: String? = nil) {
        self.dbWriter = writer
        self.recoveryMessage = recoveryMessage
    }

    /// Opens (or creates) the app database at the canonical Application Support
    /// path, recovering from corruption instead of blocking launch. (#24)
    static func open() throws -> Database {
        let url = try defaultDatabaseURL()
        let db = try openOrRecover(at: url)
        db.writeBackup(of: url)   // rolling backup after a known-good open
        return db
    }

    /// Only confirmed corruption permits recovery. Busy, permission and
    /// migration failures leave the original library in place for a retry.
    static func openOrRecover(at url: URL) throws -> Database {
        do {
            return try openMigrating(at: url)
        } catch {
            guard isCorruption(error) else { throw error }
            ClipxLog.app.error("DB corruption confirmed: \(String(describing: error), privacy: .public)")

            let fm = FileManager.default
            let directory = url.deletingLastPathComponent()
            let backup = directory.appendingPathComponent("clipx.backup.sqlite")
            let candidate = directory.appendingPathComponent(".recovery-\(UUID().uuidString).sqlite")
            defer { removeDatabaseFiles(at: candidate) }
            var restoredBackup = false
            var rejectedBackup = false
            if fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: backup, to: candidate)
                do {
                    let validated = try openMigrating(at: candidate)
                    try validated.closeForReplacement()
                    restoredBackup = true
                } catch {
                    // Preserve the failed backup as evidence. A corrupt backup
                    // must never be installed at the canonical path.
                    guard isCorruption(error) else { throw error }
                    rejectedBackup = true
                    removeDatabaseFiles(at: candidate)
                }
            }
            if !restoredBackup {
                let fresh = try openMigrating(at: candidate)
                try fresh.closeForReplacement()
            }

            if rejectedBackup { _ = try sidelineCorruptFile(at: backup) }

            let aside = try sidelineCorruptFile(at: url)
            do {
                try fm.moveItem(at: candidate, to: url)
            } catch {
                // If installation fails, put the untouched original back.
                try? moveDatabaseFiles(from: aside, to: url)
                throw error
            }
            let recovered = try openMigrating(at: url)
            let outcome = restoredBackup ? "restored from the last backup" : "recreated because no usable backup was available"
            return Database(writer: recovered.dbWriter, recoveryMessage:
                "Your library was \(outcome). The damaged database is preserved at \(aside.path).")
        }
    }

    private struct IntegrityFailure: LocalizedError {
        let details: String
        var errorDescription: String? { "Database integrity check failed: \(details)" }
    }

    /// DatabasePool keeps WAL files for reuse; closing alone does not promise
    /// the main file contains the newest migrations before a filesystem move.
    private func closeForReplacement() throws {
        try dbWriter.writeWithoutTransaction { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            guard let row, (row[0] as Int) == 0 else {
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "Could not checkpoint the recovery database")
            }
        }
        try dbWriter.close()
    }

    static func isCorruption(_ error: Error) -> Bool {
        if error is IntegrityFailure { return true }
        guard let sqlite = error as? DatabaseError else { return false }
        return sqlite.resultCode == .SQLITE_CORRUPT || sqlite.resultCode == .SQLITE_NOTADB
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
        do {
            try pool.read { db in
                let results = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard results == ["ok"] else {
                    throw IntegrityFailure(details: results.joined(separator: "; "))
                }
            }
            try Migrations.register().migrate(pool)
            return Database(writer: pool)
        } catch {
            try? pool.close()
            throw error
        }
    }

    /// Move a corrupt DB (and its WAL/SHM siblings) aside, timestamped, so the
    /// user's data is preserved for manual recovery rather than destroyed. (#24)
    private static func sidelineCorruptFile(at url: URL) throws -> URL {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).corrupt-\(UUID().uuidString).sqlite")
        try moveDatabaseFiles(from: url, to: aside)
        return aside
    }

    private static func moveDatabaseFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var moved: [String] = []
        do {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: source.path + suffix) {
                try fm.moveItem(atPath: source.path + suffix, toPath: destination.path + suffix)
                moved.append(suffix)
            }
        } catch {
            for suffix in moved.reversed() {
                try? fm.moveItem(atPath: destination.path + suffix, toPath: source.path + suffix)
            }
            throw error
        }
    }

    private static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Best-effort rolling backup of the (small) metadata DB so corruption has
    /// a recent restore point. (#24)
    func writeBackup(of url: URL) {
        let dest = url.deletingLastPathComponent().appendingPathComponent("clipx.backup.sqlite")
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString).sqlite")
        defer { Self.removeDatabaseFiles(at: scratch) }
        do {
            let target = try DatabaseQueue(path: scratch.path)
            try dbWriter.backup(to: target)
            try target.close()
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: dest)
            }
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
        // Explicit opt-in keeps verification fixtures out of the user's library.
        if let directory = AppPreferences.dataDirectory {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("clipx.sqlite")
        }
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

/// Folder membership uses a binary prefix comparison: LIKE would also match
/// a different-cased neighbour on a case-sensitive volume.
func folderDescendantPrefix(_ path: String) -> String {
    path.hasSuffix("/") ? path : path + "/"
}
