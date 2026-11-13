import SwiftUI
import SwiftData
import AppKit

/// Manage personas — reusable roles that seed a new chat's system prompt.
/// A two-column master/detail: a selectable list on the left, an edit pane on
/// the right. Reached from the "Personas" sidebar item; personas are applied to
/// a chat from the composer's persona picker.
struct PersonasManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    @State private var selectedPersonaID: Persona.ID?

    var body: some View {
        HStack(spacing: 0) {
            // Left: compact selectable list
            VStack(spacing: 0) {
                Text("Personas are reusable roles — pick one from a chat's composer to seed its system prompt.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(personas) { persona in
                            PersonaListRow(
                                persona: persona,
                                isSelected: persona.id == selectedPersonaID,
                                onTap: { selectedPersonaID = persona.id },
                                onDelete: {
                                    let deletingSelected = persona.id == selectedPersonaID
                                    context.delete(persona)
                                    context.saveOrLog()
                                    if deletingSelected {
                                        selectedPersonaID = personas.first(where: { $0.id != persona.id })?.id
                                    }
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
                addPersonaButton
                    .padding(.top, 10)
            }
            .padding(16)
            .frame(width: 240)

            Divider().overlay(Theme.line)

            // Right: edit pane for the selected persona
            Group {
                if let selected = personas.first(where: { $0.id == selectedPersonaID }) {
                    PersonaEditPane(persona: selected)
                        .id(selected.id)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a persona to edit")
                            .font(Theme.metric(11))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBG)
        .tint(Theme.amber)
        .preferredColorScheme(Theme.active.scheme)
        .onAppear {
            if selectedPersonaID == nil {
                selectedPersonaID = personas.first?.id
            }
        }
    }

    private var addPersonaButton: some View {
        Button(action: addPersona) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add Persona")
                    .font(Theme.label(11))
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .panel(Theme.popoverBG, radius: 9, stroke: Theme.amber.opacity(0.3))
        }
        .buttonStyle(.plain)
        .help("Add Persona")
    }

    private func addPersona() {
        let nextOrder = (personas.map(\.sortOrder).max() ?? 0) + 1
        let persona = Persona(name: "New Persona", icon: "person",
                              tagline: "", systemPrompt: "", sortOrder: nextOrder)
        context.insert(persona)
        context.saveOrLog()
        selectedPersonaID = persona.id
    }
}

// MARK: - Persona list row (left column)

private struct PersonaListRow: View {
    let persona: Persona
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: validIcon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Theme.amber : Theme.textMute)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(persona.name.isEmpty ? "Unnamed" : persona.name)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                if !persona.tagline.isEmpty {
                    Text(persona.tagline)
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textLo)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.alert.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("Delete persona")
            .opacity(isSelected ? 1 : 0)
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

    private var validIcon: String {
        NSImage(systemSymbolName: persona.icon, accessibilityDescription: nil) != nil
            ? persona.icon : "person"
    }
}

// MARK: - Icon picker grid (popover)

private struct IconPickerGrid: View {
    @Binding var selected: String
    @Binding var isPresented: Bool

    private static let icons: [String] = [
        "person", "brain", "brain.head.profile", "sparkles", "bolt",
        "wand.and.stars", "graduationcap", "pencil", "doc.text", "book",
        "magnifyingglass", "terminal", "hammer", "wrench.and.screwdriver",
        "cpu", "network", "globe", "shield", "lock", "key",
        "lightbulb", "flame", "leaf", "heart", "star",
        "music.note", "camera", "photo", "paintbrush", "chart.bar",
        "figure.stand", "person.2", "person.crop.circle", "robot", "ant",
        "airplane", "car", "bicycle", "ferry", "figure.run",
        "cloud", "sun.max", "moon", "wind", "drop"
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.icons, id: \.self) { sym in
                Button {
                    selected = sym
                    isPresented = false
                } label: {
                    Image(systemName: sym)
                        .font(.system(size: 14))
                        .foregroundStyle(selected == sym ? Theme.amber : Theme.textHi)
                        .frame(width: 32, height: 32)
                        .background(
                            selected == sym
                                ? Theme.amber.opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(sym)
            }
        }
        .padding(10)
        .frame(width: 344)
    }
}

// MARK: - Persona edit pane (right column)

private struct PersonaEditPane: View {
    @Bindable var persona: Persona
    @FocusState private var focus: Field?
    @State private var showIconPicker = false

    private enum Field { case name, tagline, prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FieldGroup(caption: "Name") {
                    TextField("Name", text: $persona.name)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                        .fieldChrome(focused: focus == .name)
                        .frame(width: 160)
                }
                .fixedSize()
                FieldGroup(caption: "Icon") {
                    Button {
                        showIconPicker.toggle()
                    } label: {
                        Image(systemName: persona.icon.isEmpty ? "person" : persona.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.amber)
                            .frame(width: 32, height: 28)
                            .background(Theme.windowBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.fgTint.opacity(0.10), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                        IconPickerGrid(selected: $persona.icon, isPresented: $showIconPicker)
                    }
                }
                .fixedSize()
            }

            FieldGroup(caption: "Tagline") {
                TextField("Brief descriptor", text: $persona.tagline)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .tagline)
                    .fieldChrome(focused: focus == .tagline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("System Prompt", size: 9)
                TextEditor(text: $persona.systemPrompt)
                    .font(Theme.metric(12))
                    .foregroundStyle(Theme.textHi)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .hideScrollIndicators()
                    .focused($focus, equals: .prompt)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Theme.windowBG,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(focus == .prompt
                                          ? Theme.amber.opacity(0.85)
                                          : Theme.fgTint.opacity(0.10),
                                          lineWidth: 1)
                    )
                    .animation(.snappy(duration: 0.2), value: focus == .prompt)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(20)
    }
}
