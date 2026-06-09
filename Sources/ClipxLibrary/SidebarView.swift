import SwiftUI

/// Left navigation pane: brand, library scopes, and — only when they exist —
/// collections and projects. Filters are tucked behind a collapsed disclosure
/// so the default sidebar is calm: footage-finding first, organization second.
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var collections: [Collection] = []
    @State private var projects: [Project] = []
    @State private var showNewProject = false
    @State private var showNewCollection = false
    @State private var filtersExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandHeader
                librarySection
                // Empty Collections/Projects sections used to take up space with
                // nothing but a "New…" row. They now appear only once populated;
                // creation lives in the header "+" menu.
                if !collections.isEmpty { collectionsSection }
                if !projects.isEmpty { projectsSection }
                filtersSection
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bgRaised)
        .onAppear(perform: load)
        .onChange(of: appState.bootstrapped) { _, ready in if ready { load() } }
        .onChange(of: appState.libraryRevision) { _, _ in load() }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { _ in load() }
        }
        .sheet(isPresented: $showNewCollection) {
            NewCollectionSheet { _ in load() }
        }
    }

    // MARK: - Brand + create menu

    private var brandHeader: some View {
        HStack(spacing: 6) {
            Text("clipx")
                .font(Theme.wordmark(size: 22))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Menu {
                Button("New Project…") { showNewProject = true }
                Button("New Collection…") { showNewCollection = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .foregroundStyle(Theme.textSecondary)
            .help("New project or collection")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    // MARK: - Sections

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Library")
            // Note: each row also clears any project/collection scope —
            // without this, picking "Unused" while in a Project view kept
            // the project filter, producing confusing empty results.
            SidebarRow(label: "All Clips", icon: "rectangle.stack", isActive: isAllClipsActive) {
                appState.activeFilters = ClipFilters()
                appState.selectedProjectID = nil
                appState.selectedCollectionID = nil
            }
            SidebarRow(label: "Recently Imported", icon: "clock.arrow.circlepath", isActive: isRecentlyImportedActive) {
                var f = ClipFilters()
                f.dateFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date())
                appState.activeFilters = f
                appState.selectedProjectID = nil
                appState.selectedCollectionID = nil
            }
            SidebarRow(label: "Unused", icon: "sparkles",
                       isActive: appState.activeFilters.unusedOnly && appState.selectedProjectID == nil) {
                var f = ClipFilters()
                f.unusedOnly = true
                appState.activeFilters = f
                appState.selectedProjectID = nil
                appState.selectedCollectionID = nil
            }
        }
    }

    private var isAllClipsActive: Bool {
        !appState.activeFilters.isActive
            && appState.selectedProjectID == nil
            && appState.selectedCollectionID == nil
    }

    private var isRecentlyImportedActive: Bool {
        appState.selectedProjectID == nil
            && appState.activeFilters.dateFrom != nil
            && !appState.activeFilters.unusedOnly
            && appState.activeFilters.moods.isEmpty
            && appState.activeFilters.shotTypes.isEmpty
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Collections")
            ForEach(collections) { collection in
                SidebarRow(label: collection.name, icon: "tray.full",
                           isActive: appState.selectedCollectionID == collection.id) {
                    appState.selectedCollectionID = collection.id
                }
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Projects")
            ForEach(projects) { project in
                let isSelected = appState.selectedProjectID == project.id
                SidebarRow(label: project.name, icon: "folder.fill",
                           trailing: project.status.capitalized, isActive: isSelected) {
                    if isSelected, let id = project.id {
                        appState.selectedProjectID = nil
                        appState.activeFilters.projectIDs.remove(id)
                    } else if let id = project.id {
                        appState.selectedProjectID = id
                        appState.activeFilters.projectIDs = [id]
                    }
                }
            }
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { filtersExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 16, height: 1)
                    Text("Filters").clipxSectionLabel()
                    if appState.activeFilters.isActive {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: filtersExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if filtersExpanded {
                FilterSidebar()
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 1)
            Text(title).clipxSectionLabel()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
    }

    private func load() {
        guard let db = AppEnvironment.shared.database else { return }
        do {
            collections = try db.read { try Collection.order(Collection.Columns.name).fetchAll($0) }
            projects = try db.read { try Project.order(Project.Columns.name).fetchAll($0) }
        } catch {
            ClipxLog.library.error("SidebarView.load failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// A single sidebar navigation row with a hover wash and active-tint. Its own
/// view so each row can track hover independently.
private struct SidebarRow: View {
    let label: String
    let icon: String
    var trailing: String? = nil
    var isActive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Theme.accentSoft : (hovering ? Theme.surfaceHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
