import SwiftUI

/// Right-pane inspector showing all metadata for the selected clip with
/// inline editing. Backed directly by MarkerStore / TagStore writes.
struct InspectorView: View {
    let clipID: Int64
    @State private var clip: Clip?
    @State private var source: Source?
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var suggestions: [String] = []

    private let moodOptions = ["calm", "dramatic", "energetic", "melancholic", "hopeful", "tense"]
    private let shotOptions = ["close-up", "medium", "wide", "extreme-wide"]
    private let cameraOptions = ["static", "pan", "tilt", "dolly", "handheld", "drone", "gimbal"]
    private let settingOptions = ["indoor", "outdoor", "urban", "nature", "studio"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let clip, let source {
                    header(clip: clip, source: source)
                    Divider()
                    nameAndRating(clip: clip)
                    Divider()
                    structured(clip: clip)
                    Divider()
                    tagsSection
                    Divider()
                    notesSection(clip: clip)
                    Divider()
                    technical(source: source)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 320)
        .onAppear(perform: load)
        .onChange(of: clipID) { _, _ in load() }
    }

    private func header(clip: Clip, source: Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.name ?? source.displayName).font(.headline)
            Text("Clip #\(clip.id ?? 0) from \(source.displayName)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(formatDuration(clip.durationMs), systemImage: "clock")
                Label("\(source.resolutionLabel)", systemImage: "viewfinder")
                if let fps = source.fps {
                    Label("\(Int(fps)) fps", systemImage: "speedometer")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func nameAndRating(clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: Binding(
                get: { self.clip?.name ?? "" },
                set: { newValue in
                    self.clip?.name = newValue
                    try? AppEnvironment.shared.database.write { db in
                        try db.execute(sql: "UPDATE clips SET name = ? WHERE id = ?",
                                       arguments: [newValue, clipID])
                    }
                }
            ))
            HStack {
                Text("Rating")
                ForEach(0..<5) { i in
                    Button {
                        let newRating = i + 1
                        self.clip?.rating = newRating
                        try? AppEnvironment.shared.markerStore.updateRating(clipID, rating: newRating)
                    } label: {
                        Image(systemName: i < clip.rating ? "star.fill" : "star")
                            .foregroundStyle(i < clip.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                colorPicker(currentLabel: clip.colorLabel)
            }
        }
    }

    private func colorPicker(currentLabel: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button {
                    let value: Int? = label == .none ? nil : label.rawValue
                    clip?.colorLabel = value
                    try? AppEnvironment.shared.markerStore.updateColorLabel(clipID, label: value)
                } label: {
                    Circle()
                        .fill(swiftColor(for: label))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if currentLabel == label.rawValue {
                                Circle().stroke(.primary, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func structured(clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attributes").font(.headline)
            ChipPicker(label: "Mood", options: moodOptions, selectedCSV: Binding(
                get: { self.clip?.mood ?? "" },
                set: { newValue in
                    self.clip?.mood = newValue.isEmpty ? nil : newValue
                    try? AppEnvironment.shared.markerStore.updateMood(clipID, mood: newValue.isEmpty ? nil : newValue)
                }
            ), multiSelect: true)
            ChipPicker(label: "Shot type", options: shotOptions, selectedCSV: Binding(
                get: { self.clip?.shotType ?? "" },
                set: { newValue in
                    self.clip?.shotType = newValue.isEmpty ? nil : newValue
                    try? AppEnvironment.shared.markerStore.updateStructured(clipID, shotType: newValue.isEmpty ? nil : newValue)
                }
            ), multiSelect: false)
            ChipPicker(label: "Camera", options: cameraOptions, selectedCSV: Binding(
                get: { self.clip?.cameraMove ?? "" },
                set: { newValue in
                    self.clip?.cameraMove = newValue.isEmpty ? nil : newValue
                    try? AppEnvironment.shared.markerStore.updateStructured(clipID, cameraMove: newValue.isEmpty ? nil : newValue)
                }
            ), multiSelect: false)
            ChipPicker(label: "Setting", options: settingOptions, selectedCSV: Binding(
                get: { self.clip?.setting ?? "" },
                set: { newValue in
                    self.clip?.setting = newValue.isEmpty ? nil : newValue
                    try? AppEnvironment.shared.markerStore.updateStructured(clipID, setting: newValue.isEmpty ? nil : newValue)
                }
            ), multiSelect: false)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            HStack {
                TextField("Add tag…", text: $newTag, onCommit: addTag)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.caption)
                        Button { remove(tag: tag) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
        .onChange(of: newTag) { _, value in
            suggestions = (try? AppEnvironment.shared.tagStore.suggestions(prefix: value).map(\.name)) ?? []
        }
    }

    private func notesSection(clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: Binding(
                get: { self.clip?.notes ?? "" },
                set: { newValue in
                    self.clip?.notes = newValue
                    try? AppEnvironment.shared.database.write { db in
                        try db.execute(sql: "UPDATE clips SET notes = ? WHERE id = ?",
                                       arguments: [newValue, clipID])
                    }
                }
            ))
            .frame(minHeight: 80)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    private func technical(source: Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source file").font(.headline)
            row("Path", value: source.path)
            row("Codec", value: source.codec ?? "—")
            row("Color space", value: source.colorSpace ?? "—")
            row("Online", value: source.online ? "yes" : "no — drive unplugged")
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                }
                Button("Open in QuickTime") {
                    NSWorkspace.shared.open(source.url)
                }
            }
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }

    private func load() {
        let env = AppEnvironment.shared
        guard let database = env.database else { return }
        do {
            let c: Clip? = try database.read { try Clip.fetchOne($0, key: clipID) }
            self.clip = c
            if let c, let s: Source = try database.read({ try Source.fetchOne($0, key: c.sourceID) }) {
                self.source = s
            }
            tags = (try? env.tagStore?.tags(forClip: clipID).map(\.name)) ?? []
        } catch {
            NSLog("InspectorView.load failed: \(error)")
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? AppEnvironment.shared.tagStore.addTag(trimmed, toClip: clipID)
        newTag = ""
        tags = (try? AppEnvironment.shared.tagStore.tags(forClip: clipID).map(\.name)) ?? []
    }

    private func remove(tag: String) {
        try? AppEnvironment.shared.tagStore.removeTag(tag, fromClip: clipID)
        tags = (try? AppEnvironment.shared.tagStore.tags(forClip: clipID).map(\.name)) ?? []
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let m = totalSec / 60, s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private func swiftColor(for label: ColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

/// A toggleable-chip multi/single picker for short string sets.
struct ChipPicker: View {
    let label: String
    let options: [String]
    @Binding var selectedCSV: String
    let multiSelect: Bool

    private var selected: Set<String> {
        Set(selectedCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(options, id: \.self) { opt in
                    Button {
                        toggle(opt)
                    } label: {
                        Text(opt)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(selected.contains(opt) ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(selected.contains(opt) ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ opt: String) {
        var s = selected
        if multiSelect {
            if s.contains(opt) { s.remove(opt) } else { s.insert(opt) }
        } else {
            s = s.contains(opt) ? [] : [opt]
        }
        selectedCSV = s.sorted().joined(separator: ", ")
    }
}

/// Simple flow layout for chips that wrap to multiple rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
