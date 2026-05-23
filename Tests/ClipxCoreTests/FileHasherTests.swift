import XCTest
@testable import Clipx

final class FileHasherTests: XCTestCase {
    func test_hash_isStableForSameFile() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipx-hash-\(UUID()).bin")
        try Data(repeating: 0xAB, count: 4096).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let h1 = try FileHasher.quickHash(url: temp)
        let h2 = try FileHasher.quickHash(url: temp)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64) // SHA-256 hex
    }

    func test_hash_differsForDifferentContent() throws {
        let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipx-hash-a-\(UUID()).bin")
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipx-hash-b-\(UUID()).bin")
        try Data(repeating: 0xAB, count: 4096).write(to: a)
        try Data(repeating: 0xCD, count: 4096).write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let h1 = try FileHasher.quickHash(url: a)
        let h2 = try FileHasher.quickHash(url: b)
        XCTAssertNotEqual(h1, h2)
    }

    func test_hash_differsWhenSizeDiffersEvenWithSameSampledBytes() throws {
        let small = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipx-small-\(UUID()).bin")
        let large = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipx-large-\(UUID()).bin")
        try Data(repeating: 0xAB, count: 1024).write(to: small)
        try Data(repeating: 0xAB, count: 2048).write(to: large)
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: large)
        }
        XCTAssertNotEqual(try FileHasher.quickHash(url: small), try FileHasher.quickHash(url: large))
    }
}
