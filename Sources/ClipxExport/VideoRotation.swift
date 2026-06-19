import Foundation
import CoreGraphics

/// Rotation geometry shared by the player preview and both export backends, so
/// a video rotated in the player exports identically. Degrees are clockwise
/// (0 / 90 / 180 / 270). Pure math — the AVFoundation/ffmpeg wiring lives in the
/// player controller and the backends, both of which call these.
enum VideoRotation {
    static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Output size after rotating an oriented (display) size by `degrees` CW.
    static func renderSize(oriented: CGSize, degrees: Int) -> CGSize {
        let d = normalized(degrees)
        return (d == 90 || d == 270)
            ? CGSize(width: oriented.height, height: oriented.width)
            : oriented
    }

    /// Affine transform mapping the oriented frame into a positive-quadrant
    /// canvas of `renderSize(oriented:degrees:)`. Compose this AFTER the track's
    /// preferredTransform.
    static func transform(oriented: CGSize, degrees: Int) -> CGAffineTransform {
        let w = oriented.width, h = oriented.height
        switch normalized(degrees) {
        case 90:  return CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        case 180: return CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case 270: return CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
        default:  return .identity
        }
    }

    /// ffmpeg `transpose` filter fragment for the rotation, or nil for 0°.
    /// (transpose=1 → 90° CW, transpose=2 → 90° CCW.)
    static func ffmpegFilter(degrees: Int) -> String? {
        switch normalized(degrees) {
        case 90:  return "transpose=1"
        case 180: return "transpose=1,transpose=1"
        case 270: return "transpose=2"
        default:  return nil
        }
    }
}
