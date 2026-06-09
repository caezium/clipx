import SwiftUI

/// Right-pane inspector showing all metadata for the selected clip with
/// inline editing. Backed directly by MarkerStore / TagStore writes.
///
/// Text fields debounce — name and notes both used to hammer the DB on every
/// keystroke. Now `draftName` / `draftNotes` are local @State that commit on
/// .onSubmit (Enter) or 600ms after the last keystroke for notes (where Enter
/// is a literal newline).
struct InspectorView: View {
    let clipID: Int64
    @State private var clip: Clip?
    @State private var source: Source?
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var allProjects: [Project] = []
    @State private var assignedProjectIDs: Set<Int64> = []

    // Draft values for debounced commit.
    @State private var draftName: String = ""
    @State private var draftNotes: String = ""
    @State private var notesCommitTask: Task<Void, Never>?

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
                    exportSection(clipID: clip.id ?? -1)
                    Divider()
                    nameAndRating(clip: clip)
                    Divider()
                    structured(clip: clip)
                    Divider()
                    tagsSection
                    Divider()
                    projectsSection
                    Divider()
                    notesSection
                    Divider()
                    technical(source: source)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .background(Theme.bgRaised)
        .onAppear(perform: load)
        .onChange(of: clipID) { _, _ in load() }
        .onDisappear { notesCommitTask?.cancel() }
    }

    private func header(clip: Clip, source: Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.name ?? source.displayName)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text("Clip #\(clip.id ?? 0) from \(source.displayName)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Label(formatDuration(clip.durationMs), systemImage: "clock")
                Label("\(source.resolutionLabel)", systemImage: "viewfinder")
                if let fps = source.fps {
                    Label("\(Int(fps)) fps", systemImage: "speedometer")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nameAndRating(clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Local draft committed on Enter/blur, not per keystroke.
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitName() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Rating").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer()
                    ForEach(0..<5) { i in
                        Button {
                            let newRating = i + 1
                            applyRating(newRating)
                        } label: {
                            Image(systemName: i < clip.rating ? "star.fill" : "star")
                                .foregroundStyle(i < clip.rating ? .yellow : .secondary)
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rate \(i + 1) star\(i == 0 ? "" : "s")")
                    }
                }
                HStack(spacing: 4) {
                    Text("Color").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer()
                    colorPicker(currentLabel: clip.colorLabel)
                }
            }
        }
    }

    private func commitName() {
        guard let database = AppEnvironment.shared.database else { return }
        let value = draftName
        let oldName = clip?.name
        clip?.name = value
        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE clips SET name = ? WHERE id = ?",
                    arguments: [value, clipID]
                )
            }
            AppState.shared.libraryRevision &+= 1
        } catch {
            // Roll back local state so what you see matches what's persisted.
            clip?.name = oldName
            AppState.shared.showToast("Couldn't save name: \(error.localizedDescription)", level: .error)
        }
    }

    private func applyRating(_ newRating: Int) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        let oldRating = clip?.rating
        clip?.rating = newRating
        do {
            try markerStore.updateRating(clipID, rating: newRating)
        } catch {
            clip?.rating = oldRating ?? 0
            AppState.shared.showToast("Couldn't save rating", level: .error)
        }
    }

    private func colorPicker(currentLabel: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button {
                    applyColorLabel(label)
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
                .accessibilityLabel("Color: \(label)")
            }
        }
    }

    private func applyColorLabel(_ label: ColorLabel) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        let value: Int? = label == .none ? nil : label.rawValue
        let old = clip?.colorLabel
        clip?.colorLabel = value
        do {
            try markerStore.updateColorLabel(clipID, label: value)
        } catch {
            clip?.colorLabel = old
            AppState.shared.showToast("Couldn't save color label", level: .error)
        }
    }

    private func structured(clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attributes").font(.headline)
            ChipPicker(label: "Mood", options: moodOptions, selectedCSV: Binding(
                get: { self.clip?.mood ?? "" },
                set: { newValue in applyMood(newValue) }
            ), multiSelect: true)
            ChipPicker(label: "Shot type", options: shotOptions, selectedCSV: Binding(
                get: { self.clip?.shotType ?? "" },
                set: { newValue in applyStructured(\.shotType, value: newValue) }
            ), multiSelect: false)
            ChipPicker(label: "Camera", options: cameraOptions, selectedCSV: Binding(
                get: { self.clip?.cameraMove ?? "" },
                set: { newValue in applyStructured(\.cameraMove, value: newValue) }
            ), multiSelect: false)
            ChipPicker(label: "Setting", options: settingOptions, selectedCSV: Binding(
                get: { self.clip?.setting ?? "" },
                set: { newValue in applyStructured(\.setting, value: newValue) }
            ), multiSelect: false)
        }
    }

    private func applyMood(_ newValue: String) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        let value: String? = newValue.isEmpty ? nil : newValue
        let old = clip?.mood
        clip?.mood = value
        do {
            try markerStore.updateMood(clipID, mood: value)
        } catch {
            clip?.mood = old
            AppState.shared.showToast("Couldn't save mood", level: .error)
        }
    }

    private func applyStructured(_ keyPath: WritableKeyPath<Clip, String?>, value newValue: String) {
        guard let markerStore = AppEnvironment.shared.markerStore else { return }
        let value: String? = newValue.isEmpty ? nil : newValue
        let old = clip?[keyPath: keyPath]
        clip?[keyPath: keyPath] = value
        do {
            switch keyPath {
            case \Clip.shotType:    try markerStore.updateStructured(clipID, shotType: value)
            case \Clip.cameraMove:  try markerStore.updateStructured(clipID, cameraMove: value)
            case \Clip.setting:     try markerStore.updateStructured(clipID, setting: value)
            default: return
            }
        } catch {
            clip?[keyPath: keyPath] = old
            AppState.shared.showToast("Couldn't save attribute", level: .error)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            HStack {
                TextField("Add tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                        Button { remove(tag: tag) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    .clipxChip(selected: true)
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: $draftNotes)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .onChange(of: draftNotes) { _, _ in scheduleNotesCommit() }
        }
    }

    private func scheduleNotesCommit() {
        notesCommitTask?.cancel()
        notesCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000) // 600ms idle window
            guard !Task.isCancelled else { return }
            commitNotes()
        }
    }

    private func commitNotes() {
        guard let database = AppEnvironment.shared.database else { return }
        let value = draftNotes
        let old = clip?.notes
        clip?.notes = value
        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE clips SET notes = ? WHERE id = ?",
                    arguments: [value, clipID]
                )
            }
        } catch {
            clip?.notes = old
            AppState.shared.showToast("Couldn't save notes", level: .error)
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
        guard let database = AppEnvironment.shared.database else { return }
        let store = AppEnvironment.shared.tagStore
        do {
            let c: Clip? = try database.read { try Clip.fetchOne($0, key: clipID) }
            self.clip = c
            draftName = c?.name ?? ""
            draftNotes = c?.notes ?? ""
            if let c, let s: Source = try database.read({ try Source.fetchOne($0, key: c.sourceID) }) {
                self.source = s
            }
            tags = (try? store?.tags(forClip: clipID).map(\.name)) ?? []
            allProjects = (try? database.read { try Project.order(Project.Columns.name).fetchAll($0) }) ?? []
            let assigned: [Int64] = (try? database.read { db in
                try Int64.fetchAll(db, sql: "SELECT project_id FROM clip_projects WHERE clip_id = ?", arguments: [clipID])
            }) ?? []
            assignedProjectIDs = Set(assigned)
        } catch {
            ClipxLog.library.error("InspectorView.load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func exportSection(clipID: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Menu {
                    Section("Social") {
                        Button("Reels (9:16 1080p)") { quickExport(clipID: clipID, preset: .reels) }
                        Button("TikTok") { quickExport(clipID: clipID, preset: .tiktok) }
                        Button("YouTube Shorts") { quickExport(clipID: clipID, preset: .youtubeShorts) }
                        Button("Instagram Feed (4:5)") { quickExport(clipID: clipID, preset: .instagramFeed) }
                    }
                    Section("YouTube") {
                        Button("YouTube 1080p") { quickExport(clipID: clipID, preset: .youtube1080p) }
                        Button("YouTube 4K") { quickExport(clipID: clipID, preset: .youtube4k) }
                    }
                    Section("Bridges") {
                        Button("FCPXML (Final Cut Pro)…") {
                            AppState.shared.selectedClipIDs = [clipID]
                            ExportActions.exportFCPXML()
                        }
                        Button("Obsidian Sidecar…") {
                            AppState.shared.selectedClipIDs = [clipID]
                            ExportActions.exportObsidian()
                        }
                    }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    quickExport(clipID: clipID, preset: .reels)
                } label: {
                    Image(systemName: "bolt.fill")
                }
                .buttonStyle(.bordered)
                .help("Quick export as Reels (⌘⇧R)")
            }
        }
    }

    private func quickExport(clipID: Int64, preset: ExportPreset) {
        AppState.shared.selectedClipIDs = [clipID]
        ExportActions.exportSelected(preset)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projects").font(.caption).foregroundStyle(.secondary)
            if allProjects.isEmpty {
                Text("No projects yet — create one in the sidebar.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(allProjects) { project in
                        let pid = project.id ?? -1
                        let isAssigned = assignedProjectIDs.contains(pid)
                        Button {
                            toggleProject(pid, assigned: isAssigned)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isAssigned ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.caption2)
                                Text(project.name).font(.caption)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(isAssigned ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(isAssigned ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleProject(_ projectID: Int64, assigned: Bool) {
        guard projectID >= 0, let database = AppEnvironment.shared.database else { return }
        // Optimistic update with rollback so the chip reflects truth.
        if assigned { assignedProjectIDs.remove(projectID) }
        else { assignedProjectIDs.insert(projectID) }
        do {
            try database.write { db in
                if assigned {
                    try db.execute(
                        sql: "DELETE FROM clip_projects WHERE clip_id = ? AND project_id = ?",
                        arguments: [clipID, projectID]
                    )
                } else {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO clip_projects (clip_id, project_id) VALUES (?, ?)",
                        arguments: [clipID, projectID]
                    )
                }
            }
            AppState.shared.libraryRevision &+= 1
        } catch {
            // Roll back so UI doesn't lie.
            if assigned { assignedProjectIDs.insert(projectID) }
            else { assignedProjectIDs.remove(projectID) }
            AppState.shared.showToast("Couldn't update project assignment", level: .error)
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store = AppEnvironment.shared.tagStore else { return }
        try? store.addTag(trimmed, toClip: clipID)
        newTag = ""
        tags = (try? store.tags(forClip: clipID).map(\.name)) ?? []
    }

    private func remove(tag: String) {
        guard let store = AppEnvironment.shared.tagStore else { return }
        try? store.removeTag(tag, fromClip: clipID)
        tags = (try? store.tags(forClip: clipID).map(\.name)) ?? []
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
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: 5) {
                ForEach(options, id: \.self) { opt in
                    Button { toggle(opt) } label: {
                        Text(opt).clipxChip(selected: selected.contains(opt))
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

/// Simple flow layout for chips that wrap to multiple rows. Honors the
/// container's proposed width so chips wrap properly in narrow panels.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            let w = min(sz.width, containerWidth)
            if x > 0 && x + w > containerWidth { x = 0; y += rowH + spacing; rowH = 0 }
            x += w + spacing
            rowH = max(rowH, sz.height)
        }
        let finalWidth = containerWidth.isFinite ? containerWidth : x
        return CGSize(width: finalWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let containerWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            let w = min(sz.width, containerWidth)
            if x > bounds.minX && x + w > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: sz.height))
            x += w + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
