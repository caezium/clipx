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
        do {
            var project = Project(
                id: nil,
                name: name.trimmingCharacters(in: .whitespaces),
                status: status.rawValue,
                obsidianNotePath: obsidianNote.isEmpty ? nil : obsidianNote,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            try AppEnvironment.shared.database.write { try project.insert($0) }
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
        do {
            var collection = Collection(
                id: nil,
                name: name.trimmingCharacters(in: .whitespaces),
                description: description.isEmpty ? nil : description,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            try AppEnvironment.shared.database.write { try collection.insert($0) }
            onCreated?(collection)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
