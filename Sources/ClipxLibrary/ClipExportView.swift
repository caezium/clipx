import SwiftUI

/// The same explicit selection drives single-clip and batch exports.
struct ClipExportView: View {
    let clipIDs: [Int64]
    @EnvironmentObject private var appState: AppState
    private var preset: ExportPreset { appState.inspectorExportPreset }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Video format").clipxSectionLabel()
                Picker("Video format", selection: $appState.inspectorExportPreset) {
                    ForEach(ExportPreset.allBuiltIn) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("inspector.exportPreset")

                HStack(spacing: 12) {
                    Image(systemName: preset.height > preset.width ? "rectangle.portrait" : "rectangle")
                        .font(.system(size: 24, weight: .light))
                        .frame(width: 36, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(preset.width) × \(preset.height)")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(preset.frameRate) fps · \(preset.containerExt.uppercased())")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.r3))

                Button {
                    ExportActions.export(clipIDs: clipIDs, preset: preset)
                } label: {
                    Label(clipIDs.count == 1 ? "Export clip" : "Export \(clipIDs.count) clips",
                          systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(clipIDs.isEmpty)
                .accessibilityIdentifier("inspector.exportVideo")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Continue in another app").clipxSectionLabel()
                Button {
                    ExportActions.exportFCPXML(clipIDs: clipIDs)
                } label: {
                    Label("Final Cut Pro…", systemImage: "film.stack")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
                .help("Export an FCPXML timeline")
                Button {
                    ExportActions.exportObsidian(clipIDs: clipIDs)
                } label: {
                    Label("Obsidian sidecar", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
            }
            .disabled(clipIDs.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
