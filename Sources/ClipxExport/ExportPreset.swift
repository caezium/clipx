import Foundation

/// Built-in export presets for the platforms creators ship to.
struct ExportPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let width: Int
    let height: Int
    let frameRate: Int
    let videoBitrateKbps: Int
    let audioBitrateKbps: Int
    let codec: VideoCodec
    let lufsTarget: Double?     // nil → no loudness normalization (MAS / opt-out)
    let colorPrimaries: ColorPrimaries
    let containerExt: String
    /// Whether this preset relies on ffmpeg-only capabilities (loudnorm, custom
    /// bitrate). MAS build hides or grays these out.
    let requiresFFmpeg: Bool

    enum VideoCodec: String { case h264, hevc, prores }
    enum ColorPrimaries: String { case bt709, bt2020 }

    static let reels = ExportPreset(
        id: "reels",
        displayName: "Instagram Reels",
        width: 1080, height: 1920, frameRate: 30,
        videoBitrateKbps: 12_000, audioBitrateKbps: 192,
        codec: .h264, lufsTarget: -10, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    /// TikTok benefits from 60fps for high-motion content and accepts a
    /// slightly higher bitrate ceiling than Reels. Differentiated so the
    /// preset list doesn't have two byte-identical entries.
    static let tiktok = ExportPreset(
        id: "tiktok",
        displayName: "TikTok",
        width: 1080, height: 1920, frameRate: 60,
        videoBitrateKbps: 16_000, audioBitrateKbps: 192,
        codec: .h264, lufsTarget: -10, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    static let youtubeShorts = ExportPreset(
        id: "youtube-shorts",
        displayName: "YouTube Shorts",
        width: 1080, height: 1920, frameRate: 30,
        videoBitrateKbps: 12_000, audioBitrateKbps: 192,
        codec: .h264, lufsTarget: -14, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    static let instagramFeed = ExportPreset(
        id: "instagram-feed",
        displayName: "Instagram Feed (4:5)",
        width: 1080, height: 1350, frameRate: 30,
        videoBitrateKbps: 10_000, audioBitrateKbps: 192,
        codec: .h264, lufsTarget: -10, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    static let youtube1080p = ExportPreset(
        id: "youtube-1080p",
        displayName: "YouTube 1080p",
        width: 1920, height: 1080, frameRate: 30,
        videoBitrateKbps: 10_000, audioBitrateKbps: 192,
        codec: .h264, lufsTarget: -14, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    static let youtube4k = ExportPreset(
        id: "youtube-4k",
        displayName: "YouTube 4K",
        width: 3840, height: 2160, frameRate: 30,
        videoBitrateKbps: 40_000, audioBitrateKbps: 256,
        codec: .h264, lufsTarget: -14, colorPrimaries: .bt709,
        containerExt: "mp4", requiresFFmpeg: true
    )

    static let allBuiltIn: [ExportPreset] = [
        .reels, .tiktok, .youtubeShorts, .instagramFeed, .youtube1080p, .youtube4k
    ]
}
