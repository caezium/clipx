import Foundation
import AVFoundation

/// Pulls technical metadata from a video file. Uses AVURLAsset for codec/
/// duration/resolution (native, hardware-friendly). ffprobe sidecar can be
/// invoked as a fallback for codecs AVFoundation doesn't recognize (Direct build).
enum MetadataExtractor {
    struct VideoMeta {
        var durationMs: Int64?
        var width: Int?
        var height: Int?
        var fps: Double?
        var codec: String?
        var audioChannels: Int?
        var colorSpace: String?
        var createdAt: Int64?
    }

    static func extract(url: URL) async -> VideoMeta {
        var meta = VideoMeta()
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])

        do {
            let duration = try await asset.load(.duration)
            meta.durationMs = Int64(CMTimeGetSeconds(duration) * 1000)
        } catch { /* swallow */ }

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = tracks.first {
                let naturalSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let applied = naturalSize.applying(transform)
                meta.width = Int(abs(applied.width))
                meta.height = Int(abs(applied.height))

                let frameRate = try await videoTrack.load(.nominalFrameRate)
                meta.fps = Double(frameRate)

                let descriptions = try await videoTrack.load(.formatDescriptions)
                if let first = descriptions.first {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(first)
                    meta.codec = fourCCToString(mediaSubType)
                }
            }
        } catch { /* swallow */ }

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audioTracks.first {
                let descs = try await audio.load(.formatDescriptions)
                if let desc = descs.first,
                   let abl = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    meta.audioChannels = Int(abl.pointee.mChannelsPerFrame)
                }
            }
        } catch { /* swallow */ }

        if let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
           let date = resourceValues.creationDate {
            meta.createdAt = Int64(date.timeIntervalSince1970)
        }

        meta.colorSpace = "rec709" // Default. ffprobe fallback can refine this.
        return meta
    }

    private static func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
    }
}
