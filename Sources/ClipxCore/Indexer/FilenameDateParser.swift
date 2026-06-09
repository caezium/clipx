import Foundation

/// Extracts a recording date embedded in a video filename.
///
/// Action-cam and drone footage names files with the capture timestamp
/// (`DJI_20260526143012_0003_D.MP4`, `2026-05-26 12.00.00.mov`, etc.). That is
/// a far more reliable "when did I shoot it" signal than the filesystem
/// creation date, which becomes the *copy* date the moment footage is moved
/// onto another disk — the reason a whole shoot can land under "No recording
/// date" even though the date is right there in the filename.
enum FilenameDateParser {
    // YYYYMMDD with optional separators, optionally followed by HHMMSS. The
    // year is constrained to 20xx so resolutions/bitrates ("1080", "3840")
    // can't masquerade as a date.
    private static let regex = try? NSRegularExpression(
        pattern: #"(20\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?:[-_.tT ]?([01]\d|2[0-3])[-_.:]?([0-5]\d)[-_.:]?([0-5]\d)?)?"#
    )

    /// Returns epoch seconds for the date encoded in `filename`, or nil if the
    /// filename carries no plausible date.
    static func parse(_ filename: String) -> Int64? {
        guard let regex else { return nil }
        let full = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let m = regex.firstMatch(in: filename, range: full) else { return nil }

        func intAt(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: filename) else { return nil }
            return Int(filename[r])
        }
        guard let year = intAt(1), let month = intAt(2), let day = intAt(3) else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        // Default to noon when no time is present so the timestamp lands
        // squarely inside the day regardless of timezone, never spilling over
        // a midnight boundary into the wrong calendar day.
        comps.hour = intAt(4) ?? 12
        comps.minute = intAt(5) ?? 0
        comps.second = intAt(6) ?? 0

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let date = cal.date(from: comps) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}
