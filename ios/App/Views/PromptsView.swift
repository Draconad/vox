import SwiftUI

/// Pick, write and manage the personalities.
struct PromptsView: View {

    @ObservedObject private var library = PromptLibrary.shared
    @State private var editing: PromptPreset?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(PromptLibrary.builtIns) { preset in
                    row(preset)
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("These can't be edited — tap one and choose Duplicate to make a version you can change.")
            }

            if !library.custom.isEmpty {
                Section("Yours") {
                    ForEach(library.custom) { preset in
                        row(preset)
                    }
                    .onDelete { indexes in
                        for i in indexes { library.delete(library.custom[i]) }
                    }
                }
            }

            Section {
                Button {
                    creating = true
                } label: {
                    Label("Write a new one", systemImage: "plus")
                }
            } footer: {
                Text("Keep the line about plain spoken sentences in whatever you write. Every reply here is read aloud, and a model answering in markdown makes the voice recite the asterisks.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .voxBackground()
        .navigationTitle("Personality")
        .sheet(item: $editing) { preset in
            PromptEditor(preset: preset)
        }
        .sheet(isPresented: $creating) {
            PromptEditor(preset: nil)
        }
    }

    private func row(_ preset: PromptPreset) -> some View {
        HStack(alignment: .top, spacing: 10) {
                Image(systemName: library.selectedID == preset.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(library.selectedID == preset.id ? Theme.accent : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                    Text(preset.text)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(2)
                }
                Spacer()
            Button {
                editing = preset
            } label: {
                Image(systemName: preset.isBuiltIn ? "doc.on.doc" : "square.and.pencil")
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { library.select(preset) }
        .listRowBackground(Theme.card)
    }
}

/// Write or change one. A built-in opens as a copy, since the originals stay put.
struct PromptEditor: View {
    let preset: PromptPreset?

    @ObservedObject private var library = PromptLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text = ""
    @State private var confirmDelete = false

    private var isDuplicating: Bool { preset?.isBuiltIn == true }
    private var isNew: Bool { preset == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .font(.system(size: 15))
                } header: {
                    Text("Prompt")
                } footer: {
                    Text(isDuplicating
                         ? "Saving makes a copy — the built-in original stays as it is."
                         : "Sent as the system message on every turn.")
                }

                Section {
                    Button {
                        if !text.contains("read aloud") {
                            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            text += (text.isEmpty ? "" : " ") + PromptLibrary.spokenRule
                        }
                    } label: {
                        Label("Add the \"spoken aloud\" rule", systemImage: "text.badge.plus")
                    }
                    .disabled(text.contains("read aloud"))
                }

                if let preset, !preset.isBuiltIn {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .voxBackground()
            .navigationTitle(isNew ? "New personality" : (isDuplicating ? "Duplicate" : "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = preset.map { $0.isBuiltIn ? "\($0.name) copy" : $0.name } ?? ""
                text = preset?.text ?? PromptLibrary.spokenRule
            }
            .confirmationDialog("Delete this personality?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let preset { library.delete(preset) }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset, !preset.isBuiltIn {
            library.update(preset, name: cleanName.isEmpty ? preset.name : cleanName, text: text)
        } else {
            // New, or a duplicate of a built-in: either way it becomes one of yours,
            // and is selected so the change is immediately audible.
            let created = library.add(name: cleanName, text: text)
            library.select(created)
        }
        dismiss()
    }
}
