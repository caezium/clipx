import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Drag a marked clip out of Clipx and have the file materialize at the drop
/// site (Finder, FCP, Premiere, Slack…). Uses ffmpeg in Direct builds and
/// AVAssetExportSession in MAS builds.
///
/// The transfer callback awaits the shared renderer and propagates its
/// cancellation; failed transfers leave no partial file behind.
struct ClipTransferable: Transferable {
    let clipID: Int64
    let preset: ExportPreset

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            let url = try await item.materialize()
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { item in
            "clipx-\(item.clipID)-\(item.preset.id).\(item.preset.containerExt)"
        }
    }

    /// Performs the export and returns the resulting file URL in a temp dir.
    func materialize() async throws -> URL {
        guard let database = AppEnvironment.shared.database else {
            throw NSError(domain: "clipx.transferable", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Library is not loaded yet"])
        }
        guard let clip: Clip = try database.read({ db in
            try Clip.fetchOne(db, key: clipID)
        }), let source: Source = try database.read({ db in
            try Source.fetchOne(db, key: clip.sourceID)
        }) else {
            throw NSError(domain: "clipx.transferable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Clip not found"])
        }
        // Per-drag UUID — two concurrent drags of the same clip+preset used
        // to collide and silently overwrite each other.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipx-drag-\(clipID)-\(preset.id)-\(UUID().uuidString).\(preset.containerExt)")

        let request = try ClipRenderRequest(clip: clip, source: source, preset: preset, outputURL: temp)
        _ = try await ClipRenderer.render(request)
        return temp
    }
}
