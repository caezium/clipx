import Foundation
import CoreGraphics

/// The single framing policy both export backends implement: scale the source
/// to *fill* the target (cover), then center-crop to the exact target size.
///
/// Before (#12) the ffmpeg backend letterboxed (scale-to-fit + black bars)
/// while the AVFoundation backend filled-and-cropped, so the same clip exported
/// on the Direct vs MAS build looked different. Fill+crop is the
/// platform-correct default for vertical social presets; both backends now use
/// this one policy and produce the preset's exact dimensions.
enum FramingPolicy {
    /// Uniform scale that makes the source cover the destination (the larger of
    /// the width/height ratios).
    static func fillScale(srcW: CGFloat, srcH: CGFloat, dstW: CGFloat, dstH: CGFloat) -> CGFloat {
        guard srcW > 0, srcH > 0 else { return 1 }
        return max(dstW / srcW, dstH / srcH)
    }

    /// Centered offset after scaling, so the overflow is cropped evenly on both
    /// sides of the long axis.
    static func centerOffset(scaledW: CGFloat, scaledH: CGFloat, dstW: CGFloat, dstH: CGFloat) -> (x: CGFloat, y: CGFloat) {
        ((dstW - scaledW) / 2, (dstH - scaledH) / 2)
    }

    /// The ffmpeg `-vf` filter implementing the same fill+crop to WxH.
    static func ffmpegFilter(width: Int, height: Int) -> String {
        "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height)"
    }
}
