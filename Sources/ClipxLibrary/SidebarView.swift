import SwiftUI

/// Left navigation pane: library counts, collections, projects, smart filters.
/// Uses a manual VStack inside a ScrollView so we avoid SwiftUI's sidebar
/// `Section` headers, which clip in narrow columns on macOS 26.
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var collections: [Collection] = []
    @State private var projects: [Project] = []
    @State private var showNewProject = false
    @State private var showNewCollection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                librarySection
                collectionsSection
                projectsSection
                filtersSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
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

    // MARK: - Sections

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Library")
            sidebarRow(label: "All Clips", icon: "rectangle.stack") {
                appState.activeFilters = ClipFilters()
                appState.selectedProjectID = nil
                appState.selectedCollectionID = nil
            }
            sidebarRow(label: "Recently Imported", icon: "clock.arrow.circlepath") {
                var f = ClipFilters()
                f.dateFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date())
                appState.activeFilters = f
            }
            sidebarRow(label: "Unused", icon: "sparkles") {
                var f = appState.activeFilters
                f.unusedOnly = true
                appState.activeFilters = f
            }
        }
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Collections")
            ForEach(collections) { collection in
                sidebarRow(label: collection.name, icon: "tray.full") {
                    appState.selectedCollectionID = collection.id
                }
            }
            sidebarRow(label: "New Collection…", icon: "plus.circle", muted: true) {
                showNewCollection = true
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Projects")
            ForEach(projects) { project in
                let isSelected = appState.selectedProjectID == project.id
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .frame(width: 16)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(project.status.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected, let id = project.id {
                        appState.selectedProjectID = nil
                        appState.activeFilters.projectIDs.remove(id)
                    } else if let id = project.id {
                        appState.selectedProjectID = id
                        appState.activeFilters.projectIDs = [id]
                    }
                }
            }
            sidebarRow(label: "New Project…", icon: "plus.circle", muted: true) {
                showNewProject = true
            }
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Filters")
            FilterSidebar()
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        // Wrapped in a button-style HStack with an invisible leading icon to
        // match the rows' leading offset. macOS NavigationSplitView appears to
        // give items an implicit ~24pt leading inset for icons; bare Text
        // without that inset ends up clipped in narrow columns.
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 1)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
    }

    private func sidebarRow(label: String, icon: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(muted ? .tertiary : .secondary)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(muted ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard let db = AppEnvironment.shared.database else { return }
        do {
            collections = try db.read { try Collection.order(Collection.Columns.name).fetchAll($0) }
            projects = try db.read { try Project.order(Project.Columns.name).fetchAll($0) }
        } catch {
            NSLog("SidebarView.load failed: \(error)")
        }
    }
}
