import Foundation
import OSLog

/// Shared os.Logger instances, keyed by subsystem area. Replaces ad-hoc NSLog.
/// Filter in Console.app with subsystem == "com.clipx".
public enum ClipxLog {
    private static let subsystem = "com.clipx"

    public static let app       = Logger(subsystem: subsystem, category: "app")
    public static let db        = Logger(subsystem: subsystem, category: "db")
    public static let indexer   = Logger(subsystem: subsystem, category: "indexer")
    public static let watcher   = Logger(subsystem: subsystem, category: "watcher")
    public static let player    = Logger(subsystem: subsystem, category: "player")
    public static let library   = Logger(subsystem: subsystem, category: "library")
    public static let exporter  = Logger(subsystem: subsystem, category: "export")
    public static let updater   = Logger(subsystem: subsystem, category: "updater")
    public static let bookmarks = Logger(subsystem: subsystem, category: "bookmarks")
}
