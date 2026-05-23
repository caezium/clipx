import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Drag a marked clip out of Clipx and have the file materialize at the drop
/// site (Finder, FCP, Premiere, Slack…). Uses ffmpeg in Direct builds and
/// AVAssetExportSession in MAS builds.
///
/// The export runs synchronously inside the transfer callback because the
/// destination won't accept the drop until we hand back a real URL. For very
/// long clips this can briefly hang the cursor — future versions should
/// surface a progress sheet during the drag completion.
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
        guard let clip: Clip = try AppEnvironment.shared.database.read({ db in
            try Clip.fetchOne(db, key: clipID)
        }), let source: Source = try AppEnvironment.shared.database.read({ db in
            try Source.fetchOne(db, key: clip.sourceID)
        }) else {
            throw NSError(domain: "clipx.transferable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Clip not found"])
        }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipx-drag-\(clipID)-\(preset.id).\(preset.containerExt)")
        try? FileManager.default.removeItem(at: temp)

        #if DIRECT_BUILD
        let args = FFmpegBackend.buildArguments(
            sourcePath: source.path,
            inMs: clip.inMs, outMs: clip.outMs,
            preset: preset, outputPath: temp.path
        )
        let code = try await FFmpegBackend.run(arguments: args) { _ in }
        if code != 0 {
            throw NSError(domain: "clipx.transferable", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited \(code)"])
        }
        #else
        try await AVFoundationBackend.export(
            sourcePath: source.path,
            inMs: clip.inMs, outMs: clip.outMs,
            preset: preset, outputPath: temp.path,
            onProgress: { _ in }
        )
        #endif
        return temp
    }
}
