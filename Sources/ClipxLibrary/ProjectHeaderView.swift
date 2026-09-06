import SwiftUI
import GRDB

/// Banner shown above the library grid when a project is selected. Surfaces
/// the project's metadata (name, status, clip count, total duration), and
/// gives one-click actions for what you actually do with a project: export
/// everything, change status, rename.
struct ProjectHeaderView: View {
    let projectID: Int64
    @EnvironmentObject private var appState: AppState
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var project: Project?
    @State private var clipCount: Int = 0
    @State private var totalDurationMs: Int64 = 0
    @State private var renaming: Bool = false
    @State private var editedName: String = ""
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                if renaming {
                    TextField("Project name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: 320)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                } else {
                    HStack(spacing: 6) {
                        Text(project?.name ?? "Project")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .onTapGesture(count: 2) {
                                editedName = project?.name ?? ""
                                renaming = true
                            }
                        // Visible pencil affordance — double-click on text
                        // alone has zero discoverability.
                        Button {
                            editedName = project?.name ?? ""
                            renaming = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename project").accessibilityLabel("Rename project")
                    }
                }
                Spacer(minLength: 8)
                statusPill
            }
            // Stats row
            HStack(spacing: 14) {
                stat("clock", "\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                stat("timer", formatDuration(totalDurationMs))
                Spacer()
                Button(action: {
                    appState.selectProject(nil)
                }) {
                    Label("Clear filter", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            actionButtons
                .disabled(project == nil || clipCount == 0)
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Theme.danger)
                Button("Try again", action: load).controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear(perform: load)
        .onDisappear { loadTask?.cancel(); loadGeneration = UUID() }
        .onChange(of: projectID) { _, _ in load() }
        .onChange(of: appState.libraryRevision) { _, _ in load() }
    }

    @ViewBuilder
    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .foregroundStyle(.secondary)
    }

    private var statusPill: some View {
        Menu {
            ForEach(ProjectStatus.allCases, id: \.self) { s in
                Button {
                    setStatus(s)
                } label: {
                    if project?.status == s.rawValue {
                        Label(s.label, systemImage: "checkmark")
                    } else {
                        Text(s.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text((project?.status ?? "").capitalized)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(statusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusColor: Color {
        switch project?.status {
        case "planning":  return .orange
        case "editing":   return .blue
        case "published": return .green
        case "archived":  return .gray
        default:          return .secondary
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                selectAllProjectClips()
            } label: {
                Label("Select all", systemImage: "checklist")
            }
            Menu {
                Section("Social") {
                    Button("Reels (9:16 1080p)") { exportAll(.reels) }
                    Button("TikTok") { exportAll(.tiktok) }
                    Button("YouTube Shorts") { exportAll(.youtubeShorts) }
                    Button("Instagram Feed (4:5)") { exportAll(.instagramFeed) }
                }
                Section("YouTube") {
                    Button("YouTube 1080p") { exportAll(.youtube1080p) }
                    Button("YouTube 4K") { exportAll(.youtube4k) }
                }
                Section("Bridges") {
                    Button("FCPXML…") {
                        withProjectClips { ExportActions.exportFCPXML(clipIDs: $0) }
                    }
                    Button("Obsidian Sidecars…") {
                        withProjectClips { ExportActions.exportObsidian(clipIDs: $0) }
                    }
                }
            } label: {
                Label("Export all…", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func exportAll(_ preset: ExportPreset) {
        withProjectClips { ExportActions.export(clipIDs: $0, preset: preset) }
    }

    private func selectAllProjectClips() {
        let requestedProject = projectID
        withProjectClips { ids in
            guard appState.selectedProjectID == requestedProject else { return }
            appState.selectedClipIDs = Set(ids)
        }
    }

    private func withProjectClips(_ action: @escaping @MainActor ([Int64]) -> Void) {
        guard let db = AppEnvironment.shared.database else { return }
        let pid = projectID
        Task { @MainActor in
            do {
                let ids = try await Task.detached(priority: .userInitiated) {
                    try db.read { db in
                        try Int64.fetchAll(db, sql: "SELECT clip_id FROM clip_projects WHERE project_id = ? ORDER BY clip_id", arguments: [pid])
                    }
                }.value
                action(ids)
            } catch {
                appState.showToast("Couldn't load project clips: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func setStatus(_ s: ProjectStatus) {
        guard project?.status != s.rawValue,
              let database = AppEnvironment.shared.database else { return }
        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE projects SET status = ? WHERE id = ?",
                    arguments: [s.rawValue, projectID]
                )
            }
            project?.status = s.rawValue
            AppState.shared.libraryRevision &+= 1
        } catch {
            AppState.shared.showToast("Couldn't update status", level: .error)
        }
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != project?.name,
              let database = AppEnvironment.shared.database else {
            renaming = false
            return
        }
        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE projects SET name = ? WHERE id = ?",
                    arguments: [trimmed, projectID]
                )
            }
            project?.name = trimmed
            AppState.shared.libraryRevision &+= 1
            renaming = false
        } catch {
            AppState.shared.showToast("Rename failed (name in use?)", level: .error)
        }
    }

    private func load() {
        guard let db = AppEnvironment.shared.database else { return }
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        let requestedID = projectID
        loadTask = Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) { [projectID] in
                    try db.read { dbq -> (Project?, Int, Int64) in
                        let project = try Project.fetchOne(dbq, key: projectID)
                        let row = try Row.fetchOne(dbq, sql: """
                            SELECT COUNT(*) AS n,
                                   TOTAL(CASE WHEN c.in_ms >= 0 AND c.out_ms > c.in_ms THEN c.out_ms - c.in_ms ELSE 0 END) AS dur
                            FROM clips c JOIN clip_projects cp ON cp.clip_id = c.id WHERE cp.project_id = ?
                            """, arguments: [projectID])
                        let count: Int = row?["n"] ?? 0
                        let rawDuration: Double = row?["dur"] ?? 0
                        let duration: Int64 = rawDuration >= Double(Int64.max) ? .max : Int64(max(0, rawDuration))
                        return (project, count, duration)
                    }
                }.value
                guard !Task.isCancelled, loadGeneration == generation, projectID == requestedID else { return }
                project = result.0
                clipCount = result.1
                totalDurationMs = result.2
                loadError = result.0 == nil ? "This project is no longer available." : nil
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                loadError = "Couldn't load project: \(error.localizedDescription)"
            }
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return "\(h):" + String(format: "%02d:%02d total", m, s) }
        return String(format: "%d:%02d total", m, s)
    }
}
