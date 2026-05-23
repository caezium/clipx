import Foundation
import CryptoKit

/// Fast content-aware hashing for dedup detection. Uses BLAKE2-style SHA256
/// over the first 1 MB + last 1 MB + total size. Full-file hashing for huge
/// videos would be I/O-bound; this samples-based hash is good enough for the
/// "did we already index this file?" check.
enum FileHasher {
    static func quickHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 1_048_576) ?? Data()
        let tailOffset: UInt64 = size > 1_048_576 ? size - 1_048_576 : 0
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.read(upToCount: 1_048_576) ?? Data()

        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: tail)
        var sizeBytes = size.littleEndian
        withUnsafeBytes(of: &sizeBytes) { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
