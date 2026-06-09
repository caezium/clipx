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
        // Precise timing — without this, durations on VFR / long-GOP sources
        // were off by seconds, and the clip range UI later trusted that
        // number for its end-of-source guard.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        do {
            let duration = try await asset.load(.duration)
            meta.durationMs = Int64(CMTimeGetSeconds(duration) * 1000)
        } catch {
            ClipxLog.indexer.debug("duration load failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }

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
        } catch {
            ClipxLog.indexer.debug("video tracks load failed: \(String(describing: error), privacy: .public)")
        }

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audioTracks.first {
                let descs = try await audio.load(.formatDescriptions)
                if let desc = descs.first,
                   let abl = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    meta.audioChannels = Int(abl.pointee.mChannelsPerFrame)
                }
            }
        } catch {
            ClipxLog.indexer.debug("audio tracks load failed: \(String(describing: error), privacy: .public)")
        }

        // Recording date: prefer the date embedded in the filename (the true
        // shoot date for DJI / action-cam footage) over the filesystem creation
        // date, which is really the copy/import date once footage is moved onto
        // this Mac. Fall back to the filesystem date when the name has none.
        if let fromName = FilenameDateParser.parse(url.lastPathComponent) {
            meta.createdAt = fromName
        } else if let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let date = resourceValues.creationDate {
            meta.createdAt = Int64(date.timeIntervalSince1970)
        }

        // Leave colorSpace nil rather than fabricating "rec709" — downstream
        // tooling (color grading, HDR badges) would mislabel Rec.2020 or
        // P3 footage. ffprobe sidecar can fill this in later when implemented.
        meta.colorSpace = nil
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
