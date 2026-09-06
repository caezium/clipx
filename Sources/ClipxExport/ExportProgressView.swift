import SwiftUI

/// Shows pending/in-flight export jobs with a cancel button.
///
/// Pulls the pipeline from `AppEnvironment` at appear time. If the env isn't
/// bootstrapped (shouldn't happen — the sheet is only opened from menu /
/// command palette, both of which need env), shows a friendly placeholder
/// rather than crashing on a try!.
struct ExportProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pipeline: ExportPipeline?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export queue").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let pipeline {
                ExportQueueContent(pipeline: pipeline)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Export pipeline isn't ready yet — try again in a moment.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
        .onAppear { pipeline = AppEnvironment.shared.exportPipeline }
    }

}

private struct ExportQueueContent: View {
    @ObservedObject var pipeline: ExportPipeline

    var body: some View {
        Group {
            if pipeline.currentJob == nil && pipeline.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No exports in progress").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    if let job = pipeline.currentJob {
                        jobRow(job, progress: pipeline.progress[job.id])
                    }
                    ForEach(pipeline.jobs) { job in
                        jobRow(job, progress: nil)
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button(pipeline.isCancelling ? "Cancelling…" : "Cancel All", role: .destructive) {
                        pipeline.cancelAll()
                    }
                    .disabled(pipeline.isCancelling)
                }
            }
        }
    }

    @ViewBuilder
    private func jobRow(_ job: ExportJob, progress: Double?) -> some View {
        HStack {
            Image(systemName: "arrow.up.right.square")
            VStack(alignment: .leading, spacing: 2) {
                Text(job.preset.displayName)
                Text("Clip #\(job.clipID)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = progress {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: max(0, min(1, p))).frame(width: 110)
                        .accessibilityLabel("Export progress for clip \(job.clipID)")
                    Text("\(Int((max(0, min(1, p))) * 100))%").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Queued").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
