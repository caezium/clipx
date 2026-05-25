import Foundation
import AppKit
import AVFoundation

/// Serial export queue with progress dock badge and cancellation.
///
/// Cancellation now actually propagates to the underlying
/// `AVAssetExportSession` / ffmpeg `Process` via a job-scoped canceller
/// closure — Swift task cancel alone doesn't stop them. Partial output files
/// are removed on failure / cancel so the user doesn't end up with broken
/// 0-byte mp4s scattered through the output folder.
@MainActor
final class ExportPipeline: ObservableObject {
    private let database: Database
    @Published private(set) var jobs: [ExportJob] = []
    @Published private(set) var isRunning = false
    private var currentTask: Task<Void, Never>?
    private var currentJobCanceller: (@Sendable () -> Void)?

    init(database: Database) {
        self.database = database
    }

    /// Total in-flight + queued jobs. AppDelegate uses this for the
    /// "exports still running" quit confirmation.
    var activeJobCount: Int { jobs.count + (isRunning ? 1 : 0) }

    func enqueue(clipID: Int64, preset: ExportPreset, outputDir: URL) {
        let job = ExportJob(clipID: clipID, preset: preset, outputDir: outputDir)
        jobs.append(job)
        if !isRunning { startProcessing() }
    }

    func cancelAll() {
        currentJobCanceller?()
        currentTask?.cancel()
        jobs.removeAll()
        isRunning = false
        NSApp.dockTile.badgeLabel = nil
    }

    private func startProcessing() {
        isRunning = true
        currentTask = Task { [weak self] in
            while let self, !self.jobs.isEmpty, !Task.isCancelled {
                let job = self.jobs.removeFirst()
                self.updateBadge()
                await self.runJob(job)
            }
            self?.isRunning = false
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private func updateBadge() {
        // "current + queued" — was previously off by one in the visible total.
        let total = (isRunning ? 1 : 0) + jobs.count
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    private func runJob(_ job: ExportJob) async {
        var outputURL: URL?
        do {
            guard let clip: Clip = try database.read({ db in
                try Clip.fetchOne(db, key: job.clipID)
            }) else { return }
            guard let source: Source = try database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { return }

            // Sanitize + disambiguate. Without this, two clips named "intro"
            // shared an output path and the second silently overwrote the first.
            let base = ExportPipeline.sanitizeFilename(clip.name ?? "clip-\(clip.id ?? 0)")
            let idSuffix = clip.id.map { "-\($0)" } ?? ""
            let filename = "\(base)\(idSuffix).\(job.preset.containerExt)"
            let url = job.outputDir.appendingPathComponent(filename)
            outputURL = url

            var record = ExportRecord(
                id: nil, clipID: clip.id, preset: job.preset.id,
                outputPath: url.path, bytes: nil, durationMs: clip.durationMs,
                exportedAt: Int64(Date().timeIntervalSince1970),
                status: ExportStatus.inProgress.rawValue
            )
            try database.write { try record.insert($0) }

            #if DIRECT_BUILD
            let args = FFmpegBackend.buildArguments(
                sourcePath: source.path,
                inMs: clip.inMs, outMs: clip.outMs,
                preset: job.preset, outputPath: url.path
            )
            let exitCode = try await FFmpegBackend.run(
                arguments: args,
                onCancellerRegistered: { [weak self] canceller in
                    Task { @MainActor [weak self] in
                        self?.currentJobCanceller = canceller
                    }
                }
            )
            currentJobCanceller = nil
            if exitCode != 0 {
                throw NSError(domain: "clipx.export", code: Int(exitCode),
                              userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(exitCode)"])
            }
            #else
            try await AVFoundationBackend.export(
                sourcePath: source.path,
                inMs: clip.inMs, outMs: clip.outMs,
                preset: job.preset, outputPath: url.path,
                onCancellerRegistered: { [weak self] canceller in
                    Task { @MainActor [weak self] in
                        self?.currentJobCanceller = canceller
                    }
                },
                onProgress: { _ in }
            )
            currentJobCanceller = nil
            #endif

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            record.bytes = (attrs?[.size] as? Int64) ?? 0
            record.status = ExportStatus.success.rawValue
            try database.write { try record.update($0) }

            // Guarded — was previously a force-unwrap inside force-unwrap.
            if let clipID = clip.id {
                try? AppEnvironment.shared.markerStore?.incrementUsed(clipID)
            }

            AppState.shared.showToast(
                "Exported \(filename) (\(job.preset.displayName))",
                level: .success
            )
        } catch {
            currentJobCanceller = nil
            // Clean up the partial output so the user doesn't end up with
            // junk files on disk.
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            if !(error is CancellationError) {
                AppState.shared.showToast("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    /// Strip path-illegal chars and `..` traversal from user clip names before
    /// concatenating with `outputDir`.
    static func sanitizeFilename(_ name: String) -> String {
        // Disallow path separators, NUL, and any control characters. Strip
        // ".." dot-segments outright — combined with `outputDir/foo.mp4`,
        // a name like "../../etc/passwd" would otherwise escape the dir.
        let illegal = CharacterSet(charactersIn: "/\\:?\"<>|\0")
            .union(.controlCharacters)
        var cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: "-")
        // Collapse any leading dots — ".profile" → "profile" — and remove
        // ".." segments inside.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.replacingOccurrences(of: "..", with: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "clip" : trimmed
    }
}

struct ExportJob: Identifiable {
    let id = UUID()
    let clipID: Int64
    let preset: ExportPreset
    let outputDir: URL
}
