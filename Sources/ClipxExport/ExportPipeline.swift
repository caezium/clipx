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
    /// The job currently encoding (removed from `jobs` while it runs). (#13)
    @Published private(set) var currentJob: ExportJob?
    /// Per-job 0...1 progress for the queue UI. (#13)
    @Published private(set) var progress: [UUID: Double] = [:]
    private var currentTask: Task<Void, Never>?
    /// Synchronous canceller for the running job — readable by cancelAll() with
    /// no async window. (#10)
    private let cancelBox = CancellerBox()

    private func setProgress(_ id: UUID, _ value: Double) { progress[id] = value }

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
        cancelBox.cancel()        // stops the in-flight backend synchronously (#10)
        currentTask?.cancel()
        jobs.removeAll()
        progress.removeAll()
        isRunning = false
        NSApp.dockTile.badgeLabel = nil
    }

    private func startProcessing() {
        isRunning = true
        currentTask = Task { [weak self] in
            while let self, !self.jobs.isEmpty, !Task.isCancelled {
                let job = self.jobs.removeFirst()
                self.currentJob = job
                self.progress[job.id] = 0
                self.updateBadge()
                await self.runJob(job)
                self.currentJob = nil
                self.progress[job.id] = nil
            }
            self?.isRunning = false
            self?.currentJob = nil
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

            // Sanitize + disambiguate across clips AND across repeated exports of
            // the same clip+preset, so a prior render is never silently
            // overwritten — `name-id.mp4`, then `name-id-2.mp4`, … (#16)
            let base = ExportPipeline.sanitizeFilename(clip.name ?? "clip-\(clip.id ?? 0)")
                + (clip.id.map { "-\($0)" } ?? "")
            let url = ExportPipeline.uniqueOutputURL(
                dir: job.outputDir, base: base, ext: job.preset.containerExt
            ) { FileManager.default.fileExists(atPath: $0.path) }
            let filename = url.lastPathComponent
            outputURL = url

            // Snap the cut to the source's frame grid so the exported length
            // matches the marks deterministically, not quantized to output fps. (#15)
            let fps = Double(source.fps ?? 0)
            let inMs = fps > 0 ? FrameMath.snapToFrame(ms: clip.inMs, fps: fps) : clip.inMs
            let outMs = fps > 0 ? FrameMath.snapToFrame(ms: clip.outMs, fps: fps) : clip.outMs

            var record = ExportRecord(
                id: nil, clipID: clip.id, preset: job.preset.id,
                outputPath: url.path, bytes: nil, durationMs: outMs - inMs,
                exportedAt: Int64(Date().timeIntervalSince1970),
                status: ExportStatus.inProgress.rawValue
            )
            // One history row per output path — no duplicate records. (#16)
            try database.write { db in
                try db.execute(sql: "DELETE FROM exports WHERE output_path = ?", arguments: [url.path])
                try record.insert(db)
            }

            let jobID = job.id
            #if DIRECT_BUILD
            let args = FFmpegBackend.buildArguments(
                sourcePath: source.path,
                inMs: inMs, outMs: outMs,
                preset: job.preset, outputPath: url.path,
                rotation: source.rotation,
                speed: source.speed
            )
            let exitCode = try await FFmpegBackend.run(
                arguments: args,
                durationSec: Double(outMs - inMs) / 1000.0,
                onCancellerRegistered: { [cancelBox] c in cancelBox.set(c) },           // synchronous (#10)
                onProgress: { [weak self] p in Task { @MainActor in self?.setProgress(jobID, p) } } // (#13)
            )
            cancelBox.set(nil)
            if exitCode != 0 {
                throw NSError(domain: "clipx.export", code: Int(exitCode),
                              userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(exitCode)"])
            }
            #else
            try await AVFoundationBackend.export(
                sourcePath: source.path,
                inMs: inMs, outMs: outMs,
                preset: job.preset, outputPath: url.path,
                rotation: source.rotation,
                speed: source.speed,
                onCancellerRegistered: { [cancelBox] c in cancelBox.set(c) },           // synchronous (#10)
                onProgress: { [weak self] p in Task { @MainActor in self?.setProgress(jobID, p) } } // (#13)
            )
            cancelBox.set(nil)
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
                "Exported \(filename)",
                level: .success,
                actionLabel: "Show in Finder"     // reveal the output (#32)
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            cancelBox.set(nil)
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

    /// A non-colliding output URL: `base.ext`, then `base-2.ext`, `base-3.ext`, …
    /// so re-exporting never overwrites a prior render. `exists` is injected so
    /// this stays a pure, testable function. (#16)
    nonisolated static func uniqueOutputURL(dir: URL, base: String, ext: String, exists: (URL) -> Bool) -> URL {
        let first = dir.appendingPathComponent("\(base).\(ext)")
        if !exists(first) { return first }
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Close out exports left "in progress" by a crash: mark them failed and
    /// delete any partial output. Run once at launch so no record survives as
    /// in-progress across restarts. (#17)
    nonisolated static func reconcileInterruptedExports(database: Database) {
        let inProgress = ExportStatus.inProgress.rawValue
        let stuck: [ExportRecord] = (try? database.read { db in
            try ExportRecord.fetchAll(db, sql: "SELECT * FROM exports WHERE status = ?", arguments: [inProgress])
        }) ?? []
        for rec in stuck {
            if let path = rec.outputPath { try? FileManager.default.removeItem(atPath: path) }
        }
        try? database.write { db in
            try db.execute(
                sql: "UPDATE exports SET status = ? WHERE status = ?",
                arguments: [ExportStatus.failed.rawValue, inProgress]
            )
        }
    }
}

struct ExportJob: Identifiable {
    let id = UUID()
    let clipID: Int64
    let preset: ExportPreset
    let outputDir: URL
}
