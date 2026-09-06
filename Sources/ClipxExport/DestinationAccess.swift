import Foundation

/// A lease on a picked destination. Keeping it alive retains sandbox access
/// through a queued export or a complete sidecar write.
final class DestinationAccess: @unchecked Sendable {
    enum Location: String {
        case exportFolder = "exportDefaultFolder"
        case obsidianVault = "obsidianVaultPath"

        var bookmarkKey: String { rawValue + "Bookmark" }
    }

    enum AccessError: LocalizedError {
        case chooseAgain
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .chooseAgain: return "Choose the destination folder again in Settings to restore access."
            case .unavailable(let path): return "The destination folder is unavailable: \(path)"
            }
        }
    }

    let url: URL
    private let didStartAccess: Bool

    private init(url: URL) {
        self.url = url
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
    }

    static func open(_ url: URL) -> DestinationAccess { DestinationAccess(url: url) }

    static func remember(_ url: URL, for location: Location, defaults: UserDefaults = AppPreferences.defaults) throws {
        #if MAS_BUILD
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        let access = open(url)
        defer { withExtendedLifetime(access) {} }
        let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: location.bookmarkKey)
        defaults.set(url.path, forKey: location.rawValue)
    }

    static func clear(_ location: Location, defaults: UserDefaults = AppPreferences.defaults) {
        defaults.removeObject(forKey: location.bookmarkKey)
        defaults.removeObject(forKey: location.rawValue)
    }

    static func resolve(_ location: Location, defaults: UserDefaults = AppPreferences.defaults) throws -> DestinationAccess? {
        let url: URL
        if let bookmark = defaults.data(forKey: location.bookmarkKey) {
            var stale = false
            #if MAS_BUILD
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
            #endif
            url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = open(url)
            try checkDirectory(url)
            if stale { try remember(url, for: location, defaults: defaults) }
            defaults.set(url.path, forKey: location.rawValue)
            return access
        }
        guard let path = defaults.string(forKey: location.rawValue), !path.isEmpty else { return nil }
        #if MAS_BUILD
        // A legacy path string cannot restore a sandbox grant after relaunch.
        throw AccessError.chooseAgain
        #else
        url = URL(fileURLWithPath: path, isDirectory: true)
        try checkDirectory(url)
        return open(url)
        #endif
    }

    private static func checkDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AccessError.unavailable(url.path)
        }
    }
}
