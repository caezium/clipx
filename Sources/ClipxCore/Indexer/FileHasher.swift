import Foundation
import CryptoKit

/// Fast content-aware hashing for dedup + thumbnail-cache identity. Samples
/// the first 1 MB + an interior 1 MB + the last 1 MB + the total size.
///
/// The interior window matters (#22): re-encodes often keep identical container
/// headers/footers, so head+tail+size alone collide for genuinely different
/// videos of the same length — which made one clip show another's thumbnail.
/// Sampling the middle, where the actual content differs, breaks those
/// collisions. Full-file hashing would be I/O-bound on large videos.
enum FileHasher {
    private static let window = 1_048_576   // 1 MiB per sample

    static func quickHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: window) ?? Data()

        // Interior window centered on the file's midpoint.
        let mid = size / 2
        let midOffset = mid > UInt64(window / 2) ? mid - UInt64(window / 2) : 0
        try handle.seek(toOffset: midOffset)
        let middle = try handle.read(upToCount: window) ?? Data()

        let tailOffset: UInt64 = size > UInt64(window) ? size - UInt64(window) : 0
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.read(upToCount: window) ?? Data()

        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: middle)
        hasher.update(data: tail)
        var sizeBytes = size.littleEndian
        withUnsafeBytes(of: &sizeBytes) { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
