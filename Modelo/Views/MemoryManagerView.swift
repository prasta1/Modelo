import SwiftUI

/// Master-detail manager for one memory scope: editor on the left, saved-memory
/// side menu on the right (mirrors the Presets tab layout). Backed directly by
/// `MemoryStore` files — no observable store; the list reloads on appear and
/// after every mutation, and open chats pick up edits on their next turn.
struct MemoryManagerView: View {
    let scope: MemoryScope

    @State private var memories: [Memory] = []
    @State private var selectedName: String?

    var body: some View {
        HStack(spacing: 0) {
            // Left: editor
            Group {
                if let selected = memories.first(where: { $0.name == selectedName }) {
                    MemoryEditPane(memory: selected, scope: scope,
                                   onSaved: { newName in reload(selecting: newName) },
                                   onDeleted: { reload(selecting: nil) })
                        .id(selected.name)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.textFaint)
                        Text(memories.isEmpty
                             ? "No memories saved in this scope yet.\nAdd one, or let the model save them with save_memory."
                             : "Select a memory to view or edit it.")
                            .font(Theme.metric(11))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.line)

            // Right: side menu
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(memories) { memory in
                            MemoryListRow(memory: memory,
                                          isSelected: memory.name == selectedName,
                                          onTap: { selectedName = memory.name })
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)

                Button(action: addMemory) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add Memory")
                            .font(Theme.label(11))
                    }
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .panel(Theme.popoverBG, radius: 9, stroke: Theme.amber.opacity(0.3))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

                Text("One markdown file per memory in ~/.modelo/memory.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(width: 240)
        }
        .onAppear { reload(selecting: selectedName) }
    }

    private func reload(selecting name: String?) {
        memories = MemoryStore.list(scope)
        selectedName = memories.contains { $0.name == name } ? name : nil
    }

    /// Creates a placeholder memory on disk and selects it for editing — the same
    /// immediate-create flow as "Add Preset".
    private func addMemory() {
        var name = "new-memory"
        var counter = 2
        while memories.contains(where: { $0.name == name }) {
            name = "new-memory-\(counter)"
            counter += 1
        }
        guard let memory = try? MemoryStore.save(name: name, description: "New memory",
                                                 body: "Describe the fact to remember.",
                                                 scope: scope) else { return }
        reload(selecting: memory.name)
    }
}

// MARK: - Edit pane (left column)

private struct MemoryEditPane: View {
    let memory: Memory
    let scope: MemoryScope
    let onSaved: (String) -> Void
    let onDeleted: () -> Void

    @State private var name: String
    @State private var details: String
    @State private var contentText: String
    @State private var saveError: String?
    @State private var confirmingDelete = false
    @FocusState private var focus: Field?
    private enum Field { case name, details }

    init(memory: Memory, scope: MemoryScope,
         onSaved: @escaping (String) -> Void, onDeleted: @escaping () -> Void) {
        self.memory = memory
        self.scope = scope
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: memory.name)
        _details = State(initialValue: memory.description)
        _contentText = State(initialValue: memory.body)
    }

    private var isDirty: Bool {
        name != memory.name || details != memory.description || contentText != memory.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            captioned("Name") {
                TextField("memory-name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .name)
                    .fieldChrome(focused: focus == .name)
            }

            captioned("Description — one line shown to the model in the memory index") {
                TextField("What this memory covers", text: $details)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .details)
                    .fieldChrome(focused: focus == .details)
            }

            captioned("Content") {
                TextEditor(text: $contentText)
                    .font(.mono(12))
                    .foregroundStyle(Theme.textHi)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(maxHeight: .infinity)
                    .background(Theme.windowBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.fgTint.opacity(0.10), lineWidth: 1)
                    )
            }

            if let saveError {
                Text(saveError)
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.Palette.alert)
            }

            HStack {
                if let updated = memory.updatedAt {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .font(Theme.metric(11))
                    .confirmationDialog("Delete memory?", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive, action: deleteMemory)
                    } message: {
                        Text("“\(memory.name)” will be deleted from disk. This can't be undone.")
                    }
                Button("Save", action: saveMemory)
                    .font(Theme.metric(11))
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
        }
        .padding(20)
    }

    private func saveMemory() {
        do {
            // A rename must not silently clobber a different memory whose slug the
            // new name happens to match.
            let newSlug = MemoryStore.nameSlug(name)
            if newSlug != memory.name, MemoryStore.read(name: newSlug, scope: scope) != nil {
                saveError = "A memory named “\(newSlug)” already exists — pick another name or edit that one."
                return
            }
            let saved = try MemoryStore.save(name: name, description: details, body: contentText, scope: scope)
            // A rename writes a new slug — drop the old file so it doesn't linger.
            if saved.name != memory.name {
                try MemoryStore.delete(name: memory.name, scope: scope)
            }
            saveError = nil
            onSaved(saved.name)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteMemory() {
        do {
            try MemoryStore.delete(name: memory.name, scope: scope)
            onDeleted()
        } catch {
            saveError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(caption, size: 9)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - List row (right column)

private struct MemoryListRow: View {
    let memory: Memory
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Theme.amber : Theme.textMute)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.name)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                if !memory.description.isEmpty {
                    Text(memory.description)
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Theme.amber.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.amber.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
