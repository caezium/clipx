import Foundation
import GRDB

/// Thin wrapper around a GRDB `DatabaseQueue` that owns schema migrations
/// and provides a single point of construction for the app database.
final class Database {
    let dbQueue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.dbQueue = queue
    }

    /// Opens (or creates) the app database at the canonical Application Support path.
    static func open() throws -> Database {
        let url = try defaultDatabaseURL()
        var config = Configuration()
        config.label = "clipx.db"
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try Migrations.register().migrate(queue)
        return Database(queue: queue)
    }

    /// In-memory database for tests.
    static func inMemory() throws -> Database {
        let queue = try DatabaseQueue()
        try Migrations.register().migrate(queue)
        return Database(queue: queue)
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
        try dbQueue.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}
