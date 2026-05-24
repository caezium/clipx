import SwiftUI

struct NewProjectSheet: View {
    var onCreated: ((Project) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var status: ProjectStatus = .planning
    @State private var obsidianNote: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Status", selection: $status) {
                    ForEach(ProjectStatus.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                HStack {
                    TextField("Obsidian note (optional)", text: $obsidianNote)
                    Button("…") {
                        Task { @MainActor in
                            if let path = await FolderPicker.pickFolder() {
                                obsidianNote = path
                            }
                        }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            // Reject duplicates so users don't accidentally end up with three
            // "untitled" projects after a stray double-click on Create.
            let existing: Project? = try AppEnvironment.shared.database.read { db in
                try Project.fetchOne(db, sql: "SELECT * FROM projects WHERE name = ?", arguments: [trimmed])
            }
            if existing != nil {
                self.error = "A project named \"\(trimmed)\" already exists."
                return
            }
            var project = Project(
                id: nil,
                name: trimmed,
                status: status.rawValue,
                obsidianNotePath: obsidianNote.isEmpty ? nil : obsidianNote,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            try AppEnvironment.shared.database.write { try project.insert($0) }
            AppState.shared.libraryRevision &+= 1
            onCreated?(project)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct NewCollectionSheet: View {
    var onCreated: ((Collection) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Collection").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(3...6)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let existing: Collection? = try AppEnvironment.shared.database.read { db in
                try Collection.fetchOne(db, sql: "SELECT * FROM collections WHERE name = ?", arguments: [trimmed])
            }
            if existing != nil {
                self.error = "A collection named \"\(trimmed)\" already exists."
                return
            }
            var collection = Collection(
                id: nil,
                name: trimmed,
                description: description.isEmpty ? nil : description,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            try AppEnvironment.shared.database.write { try collection.insert($0) }
            AppState.shared.libraryRevision &+= 1
            onCreated?(collection)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
