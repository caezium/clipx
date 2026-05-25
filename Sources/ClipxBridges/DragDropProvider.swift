import AppKit
import UniformTypeIdentifiers

/// Promised file provider for drag-out. Currently unused — ClipGridView uses
/// the Transferable-based `ClipTransferable` instead. Kept for reference; will
/// be removed once we've validated the Transferable path covers FCP/Premiere
/// drop targets correctly.
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
                guard let database = AppEnvironment.shared.database else {
                    completionHandler(NSError(
                        domain: "clipx.dragdrop", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Library not ready"]
                    ))
                    return
                }
                guard let clip: Clip = try database.read({ db in
                    try Clip.fetchOne(db, key: clipID)
                }), let source: Source = try database.read({ db in
                    try Source.fetchOne(db, key: clip.sourceID)
                }) else {
                    completionHandler(NSError(
                        domain: "clipx.dragdrop", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Clip not found"]
                    ))
                    return
                }
                #if DIRECT_BUILD
                let args = FFmpegBackend.buildArguments(
                    sourcePath: source.path,
                    inMs: clip.inMs, outMs: clip.outMs,
                    preset: preset, outputPath: url.path
                )
                _ = try await FFmpegBackend.run(arguments: args)
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
