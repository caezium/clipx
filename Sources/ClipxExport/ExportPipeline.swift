import Foundation
import AppKit
import Combine

/// A single serial worker owns the queue until its final job has drained.
/// Cancelling removes pending jobs but keeps the worker active during cleanup.
@MainActor
final class ExportPipeline: ObservableObject {
    private let database: Database
    private let render: ClipRenderer.Operation
    @Published private(set) var jobs: [ExportJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var currentJob: ExportJob?
    @Published private(set) var progress: [UUID: Double] = [:]
    private var currentTask: Task<Void, Never>?
    private var currentCancellation: CancellerBox?
    private var workerID: UUID?

    init(database: Database, render: @escaping ClipRenderer.Operation = {
        try await ClipRenderer.render($0, cancellation: $1, onProgress: $2)
    }) {
        self.database = database
        self.render = render
    }

    var activeJobCount: Int { jobs.count + (currentJob == nil ? 0 : 1) }

    func enqueue(clipID: Int64, preset: ExportPreset, outputDir: URL, destination: DestinationAccess? = nil) {
        jobs.append(ExportJob(clipID: clipID, preset: preset, outputDir: outputDir,
                              destination: destination ?? DestinationAccess.open(outputDir)))
        if !isRunning { startProcessing() }
        updateBadge()
    }

    func cancelAll() {
        jobs.removeAll()
        guard isRunning else { return }
        isCancelling = true
        currentCancellation?.cancel()
        currentTask?.cancel()
        updateBadge()
    }

    private func startProcessing() {
        guard !isRunning else { return }
        isRunning = true
        isCancelling = false
        let generation = UUID()
        workerID = generation
        currentTask = Task { [weak self] in
            guard let self else { return }
            while !self.jobs.isEmpty, !Task.isCancelled {
                let job = self.jobs.removeFirst()
                let cancellation = CancellerBox()
                self.currentJob = job
                self.currentCancellation = cancellation
                self.progress[job.id] = 0
                self.updateBadge()
                await self.runJob(job, cancellation: cancellation, generation: generation)
                self.progress[job.id] = nil
                self.currentJob = nil
                self.currentCancellation = nil
            }
            guard self.workerID == generation else { return }
            self.workerID = nil
            self.currentTask = nil
            self.isRunning = false
            self.isCancelling = false
            self.updateBadge()
            // Jobs queued while cancellation was draining belong to a fresh
            // worker; the cancelled task must never process or clear them.
            if !self.jobs.isEmpty { self.startProcessing() }
        }
    }

    private func updateBadge() {
        NSApp?.dockTile.badgeLabel = activeJobCount > 0 ? "\(activeJobCount)" : nil
    }

    private func runJob(_ job: ExportJob, cancellation: CancellerBox, generation: UUID) async {
        var record: ExportRecord?
        do {
            try cancellation.checkCancellation()
            guard let clip: Clip = try database.read({ try Clip.fetchOne($0, key: job.clipID) }),
                  let source: Source = try database.read({ try Source.fetchOne($0, key: clip.sourceID) }) else {
                throw NSError(domain: "clipx.export", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "The clip or its source is no longer in the library."])
            }
            let base = Self.sanitizeFilename(clip.name ?? "clip-\(job.clipID)") + "-\(job.clipID)"
            let url = Self.uniqueOutputURL(dir: job.outputDir, base: base, ext: job.preset.containerExt) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            let output = try StagedRenderOutput(destination: url)
            defer { output.cleanup() }
            let request = try ClipRenderRequest(clip: clip, source: source, preset: job.preset, outputURL: output.url)
            var entry = ExportRecord(
                id: nil, clipID: clip.id, preset: job.preset.id, outputPath: url.path,
                bytes: nil, durationMs: nil, exportedAt: Int64(Date().timeIntervalSince1970),
                status: ExportStatus.inProgress.rawValue
            )
            try database.write { try entry.insert($0) }
            record = entry
            let result = try await render(request, cancellation) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.workerID == generation, self.currentJob?.id == job.id,
                          !self.isCancelling else { return }
                    self.progress[job.id] = fraction.isFinite ? max(0, min(1, fraction)) : 0
                }
            }
            try cancellation.checkCancellation()
            try output.publish()
            entry.bytes = result.bytes
            entry.durationMs = result.durationMs
            entry.status = ExportStatus.success.rawValue
            try database.write { db in
                // A clip can be deleted while its export is running. Preserve
                // the FK's SET NULL result instead of writing a stale clip ID.
                try db.execute(sql: "UPDATE exports SET bytes = ?, duration_ms = ?, status = ? WHERE id = ?",
                               arguments: [entry.bytes, entry.durationMs, entry.status, entry.id])
                try db.execute(sql: "UPDATE clips SET used_count = used_count + 1 WHERE id = ?", arguments: [job.clipID])
            }
            record = entry
            AppState.shared.libraryRevision &+= 1
            AppState.shared.showToast("Exported \(url.lastPathComponent)", level: .success,
                                      actionLabel: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            let wasCancelled = error is CancellationError || cancellation.isCancelled || Task.isCancelled
            var historyError: Error?
            if var entry = record {
                entry.status = wasCancelled ? ExportStatus.cancelled.rawValue : ExportStatus.failed.rawValue
                do {
                    try database.write { db in
                        try db.execute(sql: "UPDATE exports SET status = ? WHERE id = ?", arguments: [entry.status, entry.id])
                    }
                }
                catch { historyError = error }
            }
            if let historyError {
                AppState.shared.showToast("Couldn't save export status: \(historyError.localizedDescription)", level: .error)
            } else if !wasCancelled {
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

    /// Close history left in progress by an interrupted process. A final path
    /// does not prove ownership: another export or application may now use it.
    /// Renderers publish only complete files and clean their private staging.
    nonisolated static func reconcileInterruptedExports(database: Database) {
        let inProgress = ExportStatus.inProgress.rawValue
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
    let destination: DestinationAccess?
}
