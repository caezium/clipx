import Foundation

enum RemotePortInput {
    static func isValid(_ port: Int) -> Bool { (1024...65535).contains(port) }

    static func parse(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), isValid(port) else { return nil }
        return port
    }
}
