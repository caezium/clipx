import Foundation

/// Parses ffmpeg `-progress pipe:2` key/value output into a 0...1 fraction so
/// the export queue can show real progress instead of an indeterminate
/// spinner. (#13)
enum FFmpegProgress {
    /// The most recent `out_time_us=` value (microseconds) in a text chunk, or
    /// nil if the chunk carried no progress line.
    static func latestOutTimeUs(_ chunk: String) -> Int64? {
        var result: Int64?
        for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("out_time_us=") {
                let v = line.dropFirst("out_time_us=".count).trimmingCharacters(in: .whitespaces)
                if let n = Int64(v) { result = n }
            }
        }
        return result
    }

    /// Clamp the encoded time against the clip duration to a 0...1 fraction.
    static func fraction(outTimeUs: Int64, durationSec: Double) -> Double {
        guard durationSec > 0 else { return 0 }
        return min(1, max(0, Double(outTimeUs) / (durationSec * 1_000_000)))
    }
}
