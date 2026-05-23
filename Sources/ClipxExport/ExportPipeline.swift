import Foundation
import AppKit

/// Serial export queue with progress dock badge and cancellation.
@MainActor
final class ExportPipeline: ObservableObject {
    private let database: Database
    @Published private(set) var jobs: [ExportJob] = []
    @Published private(set) var isRunning = false
    private var currentTask: Task<Void, Never>?

    init(database: Database) {
        self.database = database
    }

    func enqueue(clipID: Int64, preset: ExportPreset, outputDir: URL) {
        let job = ExportJob(clipID: clipID, preset: preset, outputDir: outputDir)
        jobs.append(job)
        if !isRunning { startProcessing() }
    }

    func cancelAll() {
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
        let remaining = jobs.count + 1
        NSApp.dockTile.badgeLabel = remaining > 0 ? "\(remaining)" : nil
    }

    private func runJob(_ job: ExportJob) async {
        do {
            guard let clip: Clip = try database.read({ db in
                try Clip.fetchOne(db, key: job.clipID)
            }) else { return }
            guard let source: Source = try database.read({ db in
                try Source.fetchOne(db, key: clip.sourceID)
            }) else { return }

            let filename = "\(clip.name ?? "clip-\(clip.id ?? 0)").\(job.preset.containerExt)"
            let outputURL = job.outputDir.appendingPathComponent(filename)

            // Record start
            var record = ExportRecord(
                id: nil, clipID: clip.id, preset: job.preset.id,
                outputPath: outputURL.path, bytes: nil, durationMs: clip.durationMs,
                exportedAt: Int64(Date().timeIntervalSince1970),
                status: ExportStatus.inProgress.rawValue
            )
            try database.write { try record.insert($0) }

            #if DIRECT_BUILD
            let args = FFmpegBackend.buildArguments(
                sourcePath: source.path,
                inMs: clip.inMs, outMs: clip.outMs,
                preset: job.preset, outputPath: outputURL.path
            )
            let exitCode = try await FFmpegBackend.run(arguments: args) { _ in }
            if exitCode != 0 {
                throw NSError(domain: "clipx.export", code: Int(exitCode),
                              userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(exitCode)"])
            }
            #else
            try await AVFoundationBackend.export(
                sourcePath: source.path,
                inMs: clip.inMs, outMs: clip.outMs,
                preset: job.preset, outputPath: outputURL.path,
                onProgress: { _ in }
            )
            #endif

            // Record success
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            record.bytes = (attrs?[.size] as? Int64) ?? 0
            record.status = ExportStatus.success.rawValue
            try database.write { try record.update($0) }

            // Bump used_count on the clip
            try AppEnvironment.shared.markerStore.incrementUsed(clip.id!)

            await MainActor.run {
                AppState.shared.showToast(
                    "Exported \(filename) (\(job.preset.displayName))",
                    level: .success
                )
            }
        } catch {
            await MainActor.run {
                AppState.shared.showToast("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
}

struct ExportJob: Identifiable {
    let id = UUID()
    let clipID: Int64
    let preset: ExportPreset
    let outputDir: URL
}
