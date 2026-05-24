import SwiftUI
import GRDB

/// Banner shown above the library grid when a project is selected. Surfaces
/// the project's metadata (name, status, clip count, total duration), and
/// gives one-click actions for what you actually do with a project: export
/// everything, change status, rename.
struct ProjectHeaderView: View {
    let projectID: Int64
    @EnvironmentObject private var appState: AppState
    @State private var project: Project?
    @State private var clipCount: Int = 0
    @State private var totalDurationMs: Int64 = 0
    @State private var renaming: Bool = false
    @State private var editedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                if renaming {
                    TextField("Project name", text: $editedName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: 320)
                } else {
                    Text(project?.name ?? "Project")
                        .font(.title2.weight(.semibold))
                        .onTapGesture(count: 2) {
                            editedName = project?.name ?? ""
                            renaming = true
                        }
                }
                statusPill
                Spacer()
                actionButtons
            }
            // Stats row
            HStack(spacing: 14) {
                stat("clock", "\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                stat("timer", formatDuration(totalDurationMs))
                Spacer()
                Button(action: {
                    appState.selectedProjectID = nil
                    appState.activeFilters.projectIDs = []
                }) {
                    Label("Clear filter", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
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
                        selectAllProjectClips()
                        ExportActions.exportFCPXML()
                    }
                    Button("Obsidian Sidecars…") {
                        selectAllProjectClips()
                        ExportActions.exportObsidian()
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
        selectAllProjectClips()
        ExportActions.exportSelected(preset)
    }

    private func selectAllProjectClips() {
        guard let db = AppEnvironment.shared.database else { return }
        let ids: [Int64] = (try? db.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT clip_id FROM clip_projects WHERE project_id = ?",
                arguments: [projectID]
            )
        }) ?? []
        appState.selectedClipIDs = Set(ids)
    }

    private func setStatus(_ s: ProjectStatus) {
        guard project?.status != s.rawValue else { return }
        do {
            try AppEnvironment.shared.database.write { db in
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
        guard !trimmed.isEmpty, trimmed != project?.name else {
            renaming = false
            return
        }
        do {
            try AppEnvironment.shared.database.write { db in
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
            renaming = false
        }
    }

    private func load() {
        guard let db = AppEnvironment.shared.database else { return }
        Task.detached(priority: .userInitiated) { [projectID] in
            let p: Project? = try? db.read { try Project.fetchOne($0, key: projectID) }
            let stats: (Int, Int64)? = try? db.read { dbq in
                let row = try Row.fetchOne(
                    dbq,
                    sql: """
                        SELECT COUNT(*) AS n, COALESCE(SUM(c.out_ms - c.in_ms), 0) AS dur
                        FROM clips c
                        JOIN clip_projects cp ON cp.clip_id = c.id
                        WHERE cp.project_id = ?
                    """,
                    arguments: [projectID]
                )
                let n: Int = (row?["n"] as Int?) ?? 0
                let dur: Int64 = (row?["dur"] as Int64?) ?? 0
                return (n, dur)
            }
            await MainActor.run {
                self.project = p
                self.clipCount = stats?.0 ?? 0
                self.totalDurationMs = stats?.1 ?? 0
            }
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return String(format: "%d:%02d:%02d total", h, m, s) }
        return String(format: "%d:%02d total", m, s)
    }
}
