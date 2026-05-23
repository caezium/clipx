import SwiftUI

/// Shows pending/in-flight export jobs with a cancel button.
struct ExportProgressView: View {
    @StateObject private var pipeline = AppEnvironment.shared.exportPipeline ?? ExportPipeline(database: try! Database.inMemory())
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export queue").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
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
        .padding(20)
        .frame(width: 480, height: 320)
    }
}
