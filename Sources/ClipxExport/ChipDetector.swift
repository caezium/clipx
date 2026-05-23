import Foundation

/// Detects the M-series chip variant at runtime to pick the right encoder.
/// VideoToolbox h264_videotoolbox is 4x faster than libx264 on M1 base, but
/// 20-40x slower on M1/M2/M3 Pro/Max. We must switch.
enum ChipDetector {
    enum Tier { case appleSiliconBase, appleSiliconProMax, intel, unknown }

    static func detect() -> Tier {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
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
        case .appleSiliconProMax: return "libx264" // libx264 is faster on Pro/Max
        case .intel: return "h264_videotoolbox"
        case .unknown: return "libx264"
        }
    }
}
