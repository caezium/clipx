import SwiftUI

/// Left navigation pane: library counts, collections, projects, smart filters.
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var collections: [Collection] = []
    @State private var projects: [Project] = []
    @State private var showNewProject = false
    @State private var showNewCollection = false

    var body: some View {
        List {
            Section("Library") {
                NavigationLink {
                    Text("All clips")
                } label: {
                    Label("All Clips", systemImage: "rectangle.stack")
                }
                NavigationLink {
                    Text("Recently imported")
                } label: {
                    Label("Recently Imported", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    Text("Unused")
                } label: {
                    Label("Unused", systemImage: "sparkles")
                }
            }
            Section("Collections") {
                ForEach(collections) { collection in
                    Label(collection.name, systemImage: "tray.full")
                        .onTapGesture {
                            appState.selectedCollectionID = collection.id
                        }
                }
                Button { showNewCollection = true } label: {
                    Label("New Collection…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section("Projects") {
                ForEach(projects) { project in
                    HStack {
                        Image(systemName: "folder.fill")
                        Text(project.name)
                        Spacer()
                        Text(project.status.capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        appState.selectedProjectID = project.id
                    }
                }
                Button { showNewProject = true } label: {
                    Label("New Project…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section {
                FilterSidebar()
            } header: {
                Text("Filters")
            }
        }
        .listStyle(.sidebar)
        .onAppear(perform: load)
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { _ in load() }
        }
        .sheet(isPresented: $showNewCollection) {
            NewCollectionSheet { _ in load() }
        }
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
