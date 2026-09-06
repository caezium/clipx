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
    @EnvironmentObject private var appState: AppState
    @State private var clip: Clip?
    @State private var source: Source?
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var allProjects: [Project] = []
    @State private var assignedProjectIDs: Set<Int64> = []
    @State private var allCollections: [Collection] = []
    @State private var assignedCollectionIDs: Set<Int64> = []

    // Draft values for debounced commit.
    @State private var draftName: String = ""
    @State private var draftNotes: String = ""
    @State private var notesCommitTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var saveError: String?
    @State private var loadError: String?

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
                    purposeSection(clip: clip)
                    Divider()
                    tagsSection
                    Divider()
                    notesSection
                    Divider()
                    exportSection(clipID: clip.id ?? -1)
                    Divider()
                    DisclosureGroup("Attributes") {
                        structured(clip: clip).padding(.top, 10)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Divider()
                    DisclosureGroup("Projects & collections") {
                        VStack(alignment: .leading, spacing: 12) {
                            projectsSection
                            collectionsSection
                        }.padding(.top, 10)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Divider()
                    DisclosureGroup("Source details") { technical(source: source).padding(.top, 10) }
                        .font(.system(size: 13, weight: .medium))
                } else if let loadError {
                    Text(loadError).font(.callout).foregroundStyle(Theme.textSecondary)
                    Button("Try again", action: load)
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
        .onChange(of: appState.libraryRevision) { _, _ in load() }
        .onDisappear {
            notesCommitTask?.cancel()
            loadTask?.cancel()
            loadGeneration = UUID()
            commitDraft()
        }
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
                if let fps = source.fps, fps.isFinite, fps > 0 {
                    Label("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps", systemImage: "speedometer")
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
                .accessibilityLabel("Clip name")
                .accessibilityIdentifier("inspector.name")
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitDraft() }
                .onChange(of: draftName) { _, _ in scheduleNotesCommit() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Rating").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer()
                    ForEach(0..<5) { i in
                        Button {
                            let newRating = clip.rating == i + 1 ? 0 : i + 1
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

    private func commitDraft() {
        guard let clip, let id = clip.id, let store = AppEnvironment.shared.markerStore else { return }
        InspectorDraftStore.shared.record(clip: clip, name: draftName, notes: draftNotes)
        do {
            if let saved = try InspectorDraftStore.shared.flush(id, store: store) {
                self.clip = saved
                draftName = saved.name ?? ""
                draftNotes = saved.notes ?? ""
            }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            AppState.shared.showToast("Couldn't save edits. Your draft has been kept.", level: .error,
                                      actionLabel: "Retry") {
                do { try InspectorDraftStore.shared.flush(id, store: store) }
                catch { AppState.shared.showToast("Couldn't save edits: \(error.localizedDescription)", level: .error) }
            }
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
                .accessibilityLabel("Color: \(label.displayName)")
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

    private func purposeSection(clip: Clip) -> some View {
        let activeKeys = Purposes.active.map(\.key)
        let keys = activeKeys + clip.purposeList.filter { !activeKeys.contains($0) }
        return VStack(alignment: .leading, spacing: 7) {
            Text("Purpose").clipxSectionLabel()
            FlowLayout(spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    let selected = clip.purposeList.contains(key)
                    Button {
                        do {
                            let values = try AppEnvironment.shared.markerStore?.togglePurpose(clipID, key: key)
                            if let values { self.clip?.purpose = values.isEmpty ? nil : values.joined(separator: ",") }
                        } catch {
                            appState.showToast("Couldn't save purpose: \(error.localizedDescription)", level: .error)
                        }
                    } label: {
                        Label(Purposes.title(forKey: key), systemImage: Purposes.symbol(forKey: key))
                            .clipxChip(selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
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
            case \Clip.shotType:    try markerStore.updateStructured(clipID, shotType: .set(value))
            case \Clip.cameraMove:  try markerStore.updateStructured(clipID, cameraMove: .set(value))
            case \Clip.setting:     try markerStore.updateStructured(clipID, setting: .set(value))
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
            if let saveError {
                Text("Edits are waiting to be saved: \(saveError)")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry saving", action: commitDraft)
            }
            TextEditor(text: $draftNotes)
                .accessibilityLabel("Clip notes")
                .accessibilityIdentifier("inspector.notes")
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 104)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.r1))
                .overlay(RoundedRectangle(cornerRadius: Theme.r1).stroke(Theme.border))
                .onChange(of: draftNotes) { _, _ in scheduleNotesCommit() }
        }
    }

    private func scheduleNotesCommit() {
        guard let clip else { return }
        notesCommitTask?.cancel()
        guard draftName != (clip.name ?? "") || draftNotes != (clip.notes ?? "") else { return }
        InspectorDraftStore.shared.record(clip: clip, name: draftName, notes: draftNotes)
        notesCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000) // 600ms idle window
            guard !Task.isCancelled else { return }
            commitDraft()
        }
    }

    private func technical(source: Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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

    /// Loads the clip + its tags/projects/collections off the main thread. The
    /// six DB reads used to run synchronously in `.onAppear`, which stalled the
    /// first inspector open on app startup. Results are applied back on main.
    private func load() {
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        let clipID = self.clipID
        guard let database = AppEnvironment.shared.database else { return }
        loadTask = Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try database.read { db in
                        let c = try Clip.fetchOne(db, key: clipID)
                        let source = try c.flatMap { try Source.fetchOne(db, key: $0.sourceID) }
                        let tagList = try String.fetchAll(db, sql: "SELECT t.name FROM tags t JOIN clip_tags ct ON ct.tag_id = t.id WHERE ct.clip_id = ? ORDER BY t.name", arguments: [clipID])
                        let projects = try Project.order(Project.Columns.name).fetchAll(db)
                        let assigned = try Int64.fetchAll(db, sql: "SELECT project_id FROM clip_projects WHERE clip_id = ?", arguments: [clipID])
                        let collections = try Collection.order(Collection.Columns.name).fetchAll(db)
                        let assignedC = try Int64.fetchAll(db, sql: "SELECT collection_id FROM clip_collections WHERE clip_id = ?", arguments: [clipID])
                        return (c, source, tagList, projects, assigned, collections, assignedC)
                    }
                }.value
                guard !Task.isCancelled, loadGeneration == generation else { return }
                self.clip = result.0
                loadError = result.0 == nil ? "This clip is no longer available." : nil
                if let clip = result.0 {
                    let draft = InspectorDraftStore.shared.draft(for: clip)
                    self.draftName = draft.name
                    self.draftNotes = draft.notes
                }
                self.source = result.1
                self.tags = result.2
                self.allProjects = result.3
                self.assignedProjectIDs = Set(result.4)
                self.allCollections = result.5
                self.assignedCollectionIDs = Set(result.6)
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                loadError = error.localizedDescription
                AppState.shared.showToast("Couldn't load clip: \(error.localizedDescription)", level: .error)
            }
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
                            ExportActions.exportFCPXML(clipIDs: [clipID])
                        }
                        Button("Obsidian Sidecar…") {
                            ExportActions.exportObsidian(clipIDs: [clipID])
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
        ExportActions.export(clipIDs: [clipID], preset: preset)
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

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections").font(.caption).foregroundStyle(Theme.textSecondary)
            if allCollections.isEmpty {
                Text("No collections yet — create one in the sidebar.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(allCollections) { collection in
                        let cid = collection.id ?? -1
                        let isAssigned = assignedCollectionIDs.contains(cid)
                        Button {
                            toggleCollection(cid, assigned: isAssigned)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isAssigned ? "checkmark.circle.fill" : "plus.circle").font(.caption2)
                                Text(collection.name)
                            }
                            .clipxChip(selected: isAssigned)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleCollection(_ collectionID: Int64, assigned: Bool) {
        guard collectionID >= 0, let database = AppEnvironment.shared.database else { return }
        if assigned { assignedCollectionIDs.remove(collectionID) } else { assignedCollectionIDs.insert(collectionID) }
        do {
            try database.write { db in
                if assigned {
                    try db.execute(sql: "DELETE FROM clip_collections WHERE clip_id = ? AND collection_id = ?", arguments: [clipID, collectionID])
                } else {
                    try db.execute(sql: "INSERT OR IGNORE INTO clip_collections (clip_id, collection_id) VALUES (?, ?)", arguments: [clipID, collectionID])
                }
            }
            AppState.shared.libraryRevision &+= 1
        } catch {
            if assigned { assignedCollectionIDs.insert(collectionID) } else { assignedCollectionIDs.remove(collectionID) }
            AppState.shared.showToast("Couldn't update collection", level: .error)
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store = AppEnvironment.shared.tagStore else { return }
        do {
            try store.addTag(trimmed, toClip: clipID)
            tags = try store.tags(forClip: clipID).map(\.name)
            newTag = ""
        } catch { AppState.shared.showToast("Couldn't add tag: \(error.localizedDescription)", level: .error) }
    }

    private func remove(tag: String) {
        guard let store = AppEnvironment.shared.tagStore else { return }
        do {
            try store.removeTag(tag, fromClip: clipID)
            tags = try store.tags(forClip: clipID).map(\.name)
        } catch { AppState.shared.showToast("Couldn't remove tag: \(error.localizedDescription)", level: .error) }
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
                    .accessibilityLabel("\(label): \(opt)")
                    .accessibilityValue(selected.contains(opt) ? "Selected" : "Not selected")
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
