import SwiftUI
import SwiftData

/// The landing screen shown when no conversation is open. A row of persona
/// tiles sets the assistant's role; endpoint + capability filters narrow the
/// model grid; tapping a tile starts a chat.
struct LauncherView: View {
    let discovered: [DiscoveredModel]
    let endpointFilter: UUID?
    let onLaunch: (DiscoveredModel, Persona?) -> Void
    var onUnload: ((DiscoveredModel) async -> Void)? = nil
    var onPin: ((DiscoveredModel) async -> Void)? = nil
    var onUnpin: ((DiscoveredModel) async -> Void)? = nil
    /// Re-query every server's `/models`. Wired to the "Fetch models" button.
    var onRefresh: (() async -> Void)? = nil

    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    @State private var isRefreshing = false
    @State private var selectedPersona: Persona?
    @State private var activeFilters: Set<String> = ["free"]
    @Environment(ServerRegistry.self) private var registry
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    /// Models for the selected endpoint after capability filters. Never shows
    /// more than one server — `endpointFilter` falls back to the first server.
    private var filteredModels: [DiscoveredModel] {
        let serverID = endpointFilter ?? servers.first?.id
        return discovered.filter { item in
            if let serverID, item.server.id != serverID { return false }
            let m = item.model
            // Free filter only applies to cloud endpoints — local models are always shown.
            if activeFilters.contains("free") && item.server.kind == .cloudAPI && !m.isFree { return false }
            if activeFilters.contains("vision") && !m.supportsVision   { return false }
            if activeFilters.contains("tools")  && !m.supportsToolUse  { return false }
            if activeFilters.contains("reason") && !m.supportsThinking { return false }
            return true
        }
    }

    /// The endpoint currently in view. The launcher shows one server at a time;
    /// falls back to the first configured server until auto-selection runs.
    private var selectedServer: Server? {
        servers.first { $0.id == endpointFilter } ?? servers.first
    }

    var body: some View {
        ZStack {
            Theme.windowBG.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    personaSection
                    Divider().overlay(Color.white.opacity(0.10))
                    modelSection
                }
                .padding(24)
            }
        }
    }

    // MARK: - Persona row

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Persona — optional")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(personas) { persona in
                        PersonaTile(
                            persona: persona,
                            isSelected: selectedPersona?.persistentModelID == persona.persistentModelID
                        ) {
                            selectedPersona = selectedPersona?.persistentModelID == persona.persistentModelID ? nil : persona
                        }
                    }
                }
            }
        }
    }

    // MARK: - Model grid

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            endpointHeader
            // Capability filters — left-aligned
            if !discovered.isEmpty {
                capabilityFilterRow
            }
            // One endpoint's models, or a contextual empty state.
            if filteredModels.isEmpty {
                emptyHint
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(filteredModels) { item in
                        ModelTile(item: item, persona: selectedPersona,
                                  onTap: { onLaunch(item, selectedPersona) },
                                  onUnload: onUnload.map { fn in { Task<Void, Never> { await fn(item) } } },
                                  onPin: onPin.map { fn in { Task<Void, Never> { await fn(item) } } },
                                  onUnpin: onUnpin.map { fn in { Task<Void, Never> { await fn(item) } } })
                    }
                }
            }
        }
    }

    /// Banner for the endpoint currently in view: status dot, name, and a
    /// loaded/total count. The launcher shows one server at a time — switch
    /// endpoints from the sidebar SERVERS list.
    @ViewBuilder private var endpointHeader: some View {
        if let server = selectedServer {
            let loaded = filteredModels.filter { $0.model.isLoaded }.count
            HStack(spacing: 8) {
                StatusLED(status: registry.status(for: server), size: 7, breathe: false)
                Eyebrow(server.label, color: Theme.textHi, size: 11)
                Spacer()
                Text(loaded > 0 ? "\(loaded) loaded · \(filteredModels.count)"
                                : "\(filteredModels.count) models")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                if let onRefresh {
                    Button {
                        isRefreshing = true
                        Task { await onRefresh(); isRefreshing = false }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                       value: isRefreshing)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("Fetch models — re-query every server's /models")
                }
            }
        }
    }

    /// Empty state for the selected endpoint: offline, nothing discovered, or
    /// everything filtered out.
    @ViewBuilder private var emptyHint: some View {
        if let server = selectedServer, registry.status(for: server) == .offline {
            hintRow(icon: "bolt.horizontal.circle",
                    text: "\(server.label) is offline — pick another server in the sidebar.")
        } else if discovered.contains(where: { $0.server.id == selectedServer?.id }) {
            noFilterMatchHint
        } else {
            noModelsHint
        }
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)
            Text(text)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Color.white.opacity(0.02), radius: 10)
    }

    // MARK: - Capability filter row

    private var capabilityFilterRow: some View {
        HStack(spacing: 6) {
            if selectedServer?.kind == .cloudAPI {
                CapabilityFilterChip(label: "Free",   key: "free",
                                     tint: Theme.green,
                                     active: activeFilters.contains("free"))   { toggle("free") }
            }
            CapabilityFilterChip(label: "Vision", key: "vision",
                                 tint: Theme.blue,
                                 active: activeFilters.contains("vision")) { toggle("vision") }
            CapabilityFilterChip(label: "Tools",  key: "tools",
                                 tint: Theme.amber,
                                 active: activeFilters.contains("tools"))  { toggle("tools") }
            CapabilityFilterChip(label: "Reason", key: "reason",
                                 tint: Theme.purple,
                                 active: activeFilters.contains("reason")) { toggle("reason") }
        }
    }

    private func toggle(_ key: String) {
        if activeFilters.contains(key) { activeFilters.remove(key) }
        else { activeFilters.insert(key) }
    }

    // MARK: - Empty states

    private var noFilterMatchHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textFaint)
            Text("No models match the selected filters.")
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textFaint)
            Button("Clear filters") {
                activeFilters.removeAll()
            }
            .buttonStyle(.plain)
            .font(Theme.label(10))
            .foregroundStyle(Theme.amber)
            .help("Clear all filters")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Color.white.opacity(0.02), radius: 10)
    }

    private var noModelsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)
            Text("No models available — check server connections in Settings.")
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Color.white.opacity(0.02), radius: 10)
    }
}

// MARK: - Capability filter chip

private struct CapabilityFilterChip: View {
    let label: String
    let key: String
    let tint: Color
    let active: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Text(label.uppercased())
                .font(Theme.label(9))
                .tracking(0.8)
                .foregroundStyle(active ? tint : Theme.textLo)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    active ? tint.opacity(0.15) : (hovering ? Theme.fillHi : Color.clear),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        active ? tint.opacity(0.5) : Theme.line,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Filter: \(label)")
    }
}

// MARK: - Persona tile

private struct PersonaTile: View {
    let persona: Persona
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false
    @State private var showingEdit = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: persona.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textLo)
                    Text(persona.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textHi)
                }
                Text(persona.tagline)
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? Theme.amber.opacity(0.10) :
                hovering   ? Theme.fillHi : Color.white.opacity(0.02),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.amber.opacity(0.5) : Theme.line,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "Deselect persona" : "Use \(persona.name) persona")
        .contextMenu {
            Button("Edit Persona") { showingEdit = true }
        }
        .popover(isPresented: $showingEdit) {
            PersonaEditPopover(persona: persona)
        }
    }
}

// MARK: - Persona edit popover

private struct PersonaEditPopover: View {
    @Bindable var persona: Persona
    @FocusState private var focus: Field?

    private enum Field { case name, icon, tagline, prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon preview + name field
            HStack(spacing: 10) {
                Image(systemName: validIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 24)
                TextField("Name", text: $persona.name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .focused($focus, equals: .name)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Icon (SF Symbol)", size: 9)
                    TextField("e.g. brain", text: $persona.icon)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .icon)
                        .modifier(PopoverFieldChrome(focused: focus == .icon))
                        .frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Tagline", size: 9)
                    TextField("Brief descriptor", text: $persona.tagline)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .tagline)
                        .modifier(PopoverFieldChrome(focused: focus == .tagline))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("System Prompt", size: 9)
                TextEditor(text: $persona.systemPrompt)
                    .font(Theme.metric(12))
                    .foregroundStyle(Theme.textHi)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .prompt)
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Theme.windowBG,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                focus == .prompt
                                    ? Theme.amber.opacity(0.85)
                                    : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                    )
                    .animation(.easeOut(duration: 0.15), value: focus == .prompt)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.windowBG)
        .preferredColorScheme(.dark)
    }

    private var validIcon: String {
        NSImage(systemSymbolName: persona.icon, accessibilityDescription: nil) != nil
            ? persona.icon : "person"
    }
}

private struct PopoverFieldChrome: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .font(Theme.metric(12))
            .foregroundStyle(Theme.textHi)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Theme.windowBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? Theme.amber.opacity(0.85) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Model tile

private struct ModelTile: View {
    let item: DiscoveredModel
    let persona: Persona?
    let onTap: () -> Void
    var onUnload: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onUnpin: (() -> Void)? = nil
    @State private var hovering = false
    @State private var isLoading = false
    @State private var isUnloading = false

    private var model: LMStudioModel { item.model }

    /// Trailing element of the name row: a quiet "loaded" dot at rest, the
    /// pin/eject controls on hover, or a spinner while (un)loading.
    @ViewBuilder private var trailingStatus: some View {
        if isLoading || isUnloading {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        } else if model.isLoaded {
            if hovering {
                HStack(spacing: 6) {
                    if model.keepInRam == true, let onUnpin {
                        Button(action: onUnpin) {
                            Image(systemName: "pin.slash")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textLo)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin model (allow eviction)")
                    } else if model.keepInRam != true, let onPin {
                        Button(action: onPin) {
                            Image(systemName: "pin")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textLo)
                        }
                        .buttonStyle(.plain)
                        .help("Pin model (prevent auto-eviction)")
                    }
                    if let onUnload {
                        Button {
                            isUnloading = true
                            onUnload()
                        } label: {
                            Image(systemName: "eject.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textLo)
                        }
                        .buttonStyle(.plain)
                        .help("Unload model")
                    }
                }
            } else {
                HStack(spacing: 5) {
                    if model.keepInRam == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .help("Pinned — will not be auto-evicted")
                    }
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.green.opacity(0.9), radius: 4)
                        .help("Loaded")
                }
            }
        }
    }

    var body: some View {
        Button(action: {
            isLoading = true
            onTap()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                isLoading = false
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Name + loaded dot (hover swaps the dot for pin/eject controls)
                HStack(spacing: 6) {
                    Text(model.familyName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.amber : Theme.textHi)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailingStatus
                }
                SpecStrip(model: model, showArch: false)
                HStack(spacing: 4) {
                    CapabilityChips(model: model)
                    Spacer(minLength: 0)
                    // CTA when hovering
                    if hovering && !isLoading {
                        HStack(spacing: 4) {
                            if let p = persona {
                                Text("as \(p.name)")
                                    .font(Theme.label(9))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.amber)
                            }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.amber)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(hovering ? Theme.fillHi : Color.white.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        hovering ? Theme.amber.opacity(0.4) : Theme.line,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(isLoading)
        .help("Start a chat with \(model.familyName)")
    }
}
