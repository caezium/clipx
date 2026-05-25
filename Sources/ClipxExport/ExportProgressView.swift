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
                content(for: pipeline)
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

    @ViewBuilder
    private func content(for pipeline: ExportPipeline) -> some View {
        // Wrap in a Group so SwiftUI knows we're observing pipeline.
        Group {
            if pipeline.jobs.isEmpty && !pipeline.isRunning {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No exports in progress").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(pipeline.jobs) { job in
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        VStack(alignment: .leading) {
                            Text(job.preset.displayName)
                            Text("Clip #\(job.clipID)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button("Cancel All") { pipeline.cancelAll() }
                        .foregroundStyle(.red)
                }
            }
        }
        // .onReceive forces a re-render when the pipeline publishes — the
        // pipeline is reference type so the @State var doesn't auto-observe.
        .onReceive(pipeline.objectWillChange) { _ in
            // Triggers a body re-eval.
        }
    }
}
