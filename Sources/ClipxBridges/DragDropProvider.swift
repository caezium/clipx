import AppKit
import UniformTypeIdentifiers

/// Promised file provider for drag-out: when the user drops a marked clip onto
/// FCP/Premiere/Slack/Finder, we lazily materialize the export via ffmpeg
/// at the destination URL.
final class DragDropProvider: NSObject, NSFilePromiseProviderDelegate {
    let clipID: Int64
    let preset: ExportPreset

    init(clipID: Int64, preset: ExportPreset) {
        self.clipID = clipID
        self.preset = preset
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        return "clipx-\(clipID).\(preset.containerExt)"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                guard let clip: Clip = try AppEnvironment.shared.database.read({ db in
                    try Clip.fetchOne(db, key: clipID)
                }), let source: Source = try AppEnvironment.shared.database.read({ db in
                    try Source.fetchOne(db, key: clip.sourceID)
                }) else {
                    completionHandler(NSError(domain: "clipx.dragdrop", code: -1))
                    return
                }
                #if DIRECT_BUILD
                let args = FFmpegBackend.buildArguments(
                    sourcePath: source.path,
                    inMs: clip.inMs, outMs: clip.outMs,
                    preset: preset, outputPath: url.path
                )
                _ = try await FFmpegBackend.run(arguments: args) { _ in }
                #else
                try await AVFoundationBackend.export(
                    sourcePath: source.path,
                    inMs: clip.inMs, outMs: clip.outMs,
                    preset: preset, outputPath: url.path,
                    onProgress: { _ in }
                )
                #endif
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }
}
