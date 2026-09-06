import Foundation

/// Cached chip detection for the existing encoder preference. Actual encoder
/// throughput depends on the footage, preset, and current system load.
enum ChipDetector {
    enum Tier { case appleSiliconBase, appleSiliconProMax, intel, unknown }

    private static let cachedTier: Tier = detectUncached()

    static func detect() -> Tier { cachedTier }

    private static func detectUncached() -> Tier {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return .unknown }
        var brand = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0) == 0 else { return .unknown }
        let brandName = String(cString: brand).lowercased()

        if brandName.contains("apple") {
            if brandName.contains("pro") || brandName.contains("max") || brandName.contains("ultra") {
                return .appleSiliconProMax
            }
            return .appleSiliconBase
        }
        if brandName.contains("intel") { return .intel }
        return .unknown
    }

    /// Returns the recommended ffmpeg video codec arg for this chip.
    static func recommendedH264Codec() -> String {
        switch detect() {
        case .appleSiliconBase: return "h264_videotoolbox"
        case .appleSiliconProMax: return "libx264"
        case .intel: return "h264_videotoolbox"
        case .unknown: return "libx264"
        }
    }
}
