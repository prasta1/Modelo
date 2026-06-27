import SwiftUI
import SwiftData
import AppKit

/// Server management: edit LM Studio host/port, manage cloud API endpoints,
/// and paste the Firecrawl API key (stored in Keychain, not SwiftData).
///
/// Built as a bespoke instrument-panel layout rather than a `.grouped` `Form`:
/// on macOS a `Form` renders each `TextField`'s title as a visible inline label,
/// which collided with the host/port fields and the section labels and broke the
/// layout. Hand-laying the rows gives full control of the chrome and matches the
/// app's monospaced "telemetry" look.
struct SettingsView: View {
    /// When `true` the view fills the detail pane instead of a fixed-size window.
    var isInline: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(MCPServerManager.self) private var mcpManager
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    private let keychain = KeychainStore()
    @State private var selectedTab = "Servers"

    private static let tabTitles = ["Servers", "Cloud APIs", "Personas", "Sampling",
                                    "Presets", "Appearance", "Tools", "MCP Servers"]

    private var localServers: [Server] { servers.filter { $0.kind.isLocal } }
    private var cloudServers: [Server] { servers.filter { $0.kind == .cloudAPI || $0.kind == .openRouter } }

    var body: some View {
        if isInline {
            tabContent
        } else {
            tabContent
                .frame(minWidth: 580, idealWidth: 700, maxWidth: .infinity,
                       minHeight: 480, idealHeight: 580, maxHeight: .infinity)
                // Override the main window's .toolbarBackground(.hidden) so the tab
                // strip has an opaque background and scroll content doesn't bleed through.
                .toolbarBackground(Theme.windowBG, for: .windowToolbar)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(spacing: 0) {
            // Themed segmented tab bar (matches the Reports range selector) instead of
            // a system TabView — avoids the macOS-26 Liquid Glass mis-rendering and keeps
            // macOS 14 support.
            SegmentedPills(options: Self.tabTitles, selection: $selectedTab, boxed: true)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            Divider().overlay(Theme.line)
            Group {
                switch selectedTab {
                case "Cloud APIs":  cloudAPIsTab
                case "Personas":    personasTab
                case "Sampling":    SamplingSettingsTab()
                case "Presets":     PresetsSettingsTab()
                case "Appearance":  AppearanceSettingsTab()
                case "Tools":       toolsTab
                case "MCP Servers": mcpServersTab
                default:            serversTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBG)
        .tint(Theme.amber)
        .preferredColorScheme(Theme.active.scheme)
    }

    // MARK: Servers
    private var serversTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(localServers) { server in
                    ServerSettingsRow(server: server) {
                        context.delete(server)
                        try? context.save()
                    }
                }
                addButton("Add Server", action: addServer)
            }
            .padding(24)
        }
        .clipped()
    }

    // MARK: Cloud APIs
    private var cloudAPIsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(cloudServers) { server in
                    CloudServerSettingsRow(server: server, keychain: keychain) {
                        context.delete(server)
                        try? context.save()
                    }
                }
                addButton("Add Cloud API", action: addCloudServer)
            }
            .padding(24)
        }
        .clipped()
    }

    // MARK: Personas
    private var personasTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(personas) { persona in
                    PersonaSettingsRow(persona: persona) {
                        context.delete(persona)
                        try? context.save()
                    }
                }
                addButton("Add Persona", action: addPersona)
            }
            .padding(24)
        }
        .clipped()
    }

    // MARK: Tools
    private var toolsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                GlobalToolsCard()
                FilesystemToolsCard()
                ToolRoundsCard()
                ArtifactsCard()
                KeyCard(caption: "Firecrawl API key",
                        placeholder: "fc-…",
                        hint: "Enables firecrawl_scrape and firecrawl_search for tool-capable models.",
                        account: FirecrawlClient.keychainAccount,
                        keychain: keychain)
            }
            .padding(24)
        }
        .clipped()
    }

    // MARK: MCP Servers
    private var mcpServersTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(mcpManager.configs) { config in
                    MCPServerSettingsRow(
                        config: config,
                        error: mcpManager.connectionErrors[config.id],
                        onUpdate: { mcpManager.updateConfig($0) },
                        onDelete: { mcpManager.removeConfig(id: config.id) }
                    )
                }
                addButton("Add MCP Server", action: addMCPServer)
                Text("MCP servers run as local processes. New tools are available when you start the next chat.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .overlay(Theme.line)
                    .padding(.vertical, 6)

                MCPDiscoverySection(installed: mcpManager.configs) { entry in
                    mcpManager.addConfig(entry.makeConfig())
                }
            }
            .padding(24)
        }
        .clipped()
    }

    private func addButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(Theme.label(11))
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .panel(Theme.popoverBG, radius: 9,
                   stroke: Theme.amber.opacity(0.3))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func addMCPServer() {
        mcpManager.addConfig(MCPServerConfig(
            name: "New MCP Server",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/"],
            isEnabled: false
        ))
    }

    private func addCloudServer() {
        let nextOrder = (servers.map(\.sortOrder).max() ?? 0) + 1
        let server = Server(label: "Cloud API", host: "", port: 0, sortOrder: nextOrder, kind: .cloudAPI)
        context.insert(server)
        try? context.save()
    }

    private func addServer() {
        let nextOrder = (localServers.map(\.sortOrder).max() ?? 0) + 1
        let server = Server(label: "New Server", host: "localhost", port: 1234, sortOrder: nextOrder)
        context.insert(server)
        try? context.save()
    }

    private func addPersona() {
        let nextOrder = (personas.map(\.sortOrder).max() ?? 0) + 1
        let persona = Persona(name: "New Persona", icon: "person",
                              tagline: "", systemPrompt: "", sortOrder: nextOrder)
        context.insert(persona)
        try? context.save()
    }
}

// MARK: - Persona row

private struct PersonaSettingsRow: View {
    @Bindable var persona: Persona
    let onDelete: () -> Void
    @FocusState private var focus: Field?
    @State private var isExpanded = false

    private enum Field { case name, icon, tagline, prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: always visible — tap to expand/collapse
            HStack(spacing: 10) {
                Image(systemName: validIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 24)
                Text(persona.name.isEmpty ? "Unnamed" : persona.name)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                if !persona.tagline.isEmpty {
                    Text("·")
                        .foregroundStyle(Theme.textFaint)
                    Text(persona.tagline)
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.textLo)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete persona")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() } }
            .help(isExpanded ? "Collapse persona" : "Edit persona")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        FieldGroup(caption: "Name") {
                            TextField("Name", text: $persona.name)
                                .textFieldStyle(.plain)
                                .focused($focus, equals: .name)
                                .fieldChrome(focused: focus == .name)
                                .frame(width: 140)
                        }
                        .fixedSize()
                        FieldGroup(caption: "Icon (SF Symbol)") {
                            TextField("e.g. brain", text: $persona.icon)
                                .textFieldStyle(.plain)
                                .focused($focus, equals: .icon)
                                .fieldChrome(focused: focus == .icon)
                                .frame(width: 140)
                        }
                        .fixedSize()
                    }

                    FieldGroup(caption: "Tagline") {
                        TextField("Brief descriptor", text: $persona.tagline)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .tagline)
                            .fieldChrome(focused: focus == .tagline)
                    }

                    FieldGroup(caption: "System Prompt") {
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
                                    .strokeBorder(focus == .prompt
                                                  ? Theme.amber.opacity(0.85)
                                                  : Color.white.opacity(0.10),
                                                  lineWidth: 1)
                            )
                            .animation(.snappy(duration: 0.2), value: focus == .prompt)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .panel(Theme.popoverBG)
    }

    /// Falls back to "person" if the entered symbol name doesn't resolve.
    private var validIcon: String {
        NSImage(systemSymbolName: persona.icon, accessibilityDescription: nil) != nil
            ? persona.icon : "person"
    }
}

// MARK: - Sampling defaults (§1.4)

/// Edits the global default `SamplingParams` (stored JSON-encoded in `@AppStorage`)
/// that every conversation inherits unless it sets its own override. Each control
/// has an on/off pill: off means the parameter isn't sent at all, so the server
/// falls back to its own default.
private struct SamplingSettingsTab: View {
    @AppStorage("globalSamplingJSON") private var json = "{}"
    @State private var params = SamplingParams()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection("Generation defaults") {
                    Text("Applied to every conversation unless it overrides them. A disabled control isn't sent — the server uses its own default.")
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)

                    SamplingControls(params: $params)
                }
            }
            .padding(24)
        }
        .clipped()
        .onAppear {
            params = (try? JSONDecoder().decode(SamplingParams.self, from: Data(json.utf8))) ?? SamplingParams()
        }
        .onChange(of: params) { _, new in
            json = String(decoding: (try? JSONEncoder().encode(new)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }
}

// MARK: - Presets (§1.4b)

/// CRUD for reusable generation presets — a name, optional system prompt, and a set
/// of sampling controls. Apply them to a conversation from the chat header.
private struct PresetsSettingsTab: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(presets) { preset in
                    PresetSettingsRow(preset: preset) {
                        context.delete(preset)
                        try? context.save()
                    }
                }
                Button(action: addPreset) {
                    Label("Add Preset", systemImage: "plus")
                        .font(Theme.metric(12))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .help("Add a preset")
                .padding(.top, 4)

                Text("Apply a preset to a chat from the sliders button in its header.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
        .clipped()
    }

    private func addPreset() {
        context.insert(Preset(name: "New Preset", sortOrder: presets.count))
        try? context.save()
    }
}

/// Toggles the artifact behavior (§2.4): when on, the model is taught to emit
/// `<artifact>` blocks that render in the side panel instead of inline.
/// Global cap on agentic tool rounds per turn. Seeds every new `ChatSession` and
/// updates open chats live (`ChatView` observes the same key).
private struct ToolRoundsCard: View {
    @AppStorage("globalMaxToolRounds") private var maxRounds = ChatSession.defaultMaxToolRounds

    var body: some View {
        SettingsSection("Tool-call limit") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: $maxRounds, in: 1...20) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max tool calls per turn").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                            Text("How many tool rounds a model may run before the turn stops with a notice.")
                                .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                        }
                        Spacer(minLength: 8)
                        Text("\(maxRounds)").font(.mono(13)).foregroundStyle(Theme.amber).monospacedDigit()
                    }
                }
                Text("Higher allows more complex multi-step tool use but can run longer. Applies to new chats immediately; open chats update live.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Master switch for all tool use. Mirrors the per-conversation Tools toggle and
/// gates `ChatSession`'s tool offering globally; when off, no model is given tools.
private struct GlobalToolsCard: View {
    @AppStorage("toolsGloballyEnabled") private var enabled = true

    var body: some View {
        SettingsSection("Tools") {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable tools").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                    Text("Allow models to call tools (file access, web search, MCP). Can also be toggled per conversation.")
                        .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

private struct ArtifactsCard: View {
    @AppStorage("artifactsEnabled") private var enabled = true

    var body: some View {
        SettingsSection("Artifacts") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Render artifacts in a side panel").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                        Text("Substantial HTML / SVG / Mermaid / code / documents open in a viewer beside the chat, with live preview and versions.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                Text("Adds a short instruction to the system prompt teaching the model the artifact syntax. Turn off to save context on small models. Re-open a chat after changing.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Opt-in controls for the first-party filesystem/shell tools. Off by default; a
/// workspace folder is required, and mutating actions still confirm in chat.
private struct FilesystemToolsCard: View {
    @AppStorage(FSToolSettings.enabledKey) private var enabled = false
    @AppStorage(FSToolSettings.shellKey)   private var shell = false
    @AppStorage(FSToolSettings.rootKey)    private var root = ""

    var body: some View {
        SettingsSection("Filesystem & shell tools") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let models read & edit files").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                        Text("read_file · write_file · edit_file · grep · glob — confined to the workspace folder below.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMute)
                    Text(root.isEmpty ? "~/.modelo  (default sandbox)" : root)
                        .font(.mono(11))
                        .foregroundStyle(root.isEmpty ? Theme.textLo : Theme.textMid)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !root.isEmpty {
                        Button("Reset", action: { root = "" })
                            .font(Theme.metric(11))
                            .help("Use the default ~/.modelo sandbox")
                    }
                    Button(root.isEmpty ? "Choose folder…" : "Change…", action: chooseFolder)
                        .font(Theme.metric(11))
                }
                .opacity(enabled ? 1 : 0.5)

                Toggle(isOn: $shell) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow the bash tool").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                        Text("Runs shell commands in the workspace. Highest risk — every command asks for approval.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)

                Text("Off by default. Writes, edits, and shell commands always ask for approval in the chat. The model must support tools and the chat's Tools toggle must be on. Re-open a chat after changing these.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
            if !enabled { enabled = true }
        }
    }
}

/// Theme picker (§3.5): a swatch + label per palette, applied live via `@AppStorage`.
private struct AppearanceSettingsTab: View {
    @AppStorage("themeID") private var themeID = ThemeID.dark.rawValue
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection("General") {
                    Toggle(isOn: $showMenuBarIcon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show menu bar icon").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                            Text("Adds a menu bar item with a quick ephemeral chat popover.")
                                .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .toggleStyle(.switch)
                }
                SettingsSection("Theme") {
                    VStack(spacing: 8) {
                        ForEach(ThemeID.allCases) { theme in
                            ThemeRow(theme: theme, selected: themeID == theme.rawValue) {
                                themeID = theme.rawValue
                            }
                        }
                    }
                }
                Text("Chat text size lives in the View menu (⌘+ / ⌘- / ⌘0) and the A−/A+ control in a chat header.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
        .clipped()
    }
}

private struct ThemeRow: View {
    let theme: ThemeID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    ForEach(Array([p.windowBG, p.panelHigh, p.amber, p.green, p.textHi].enumerated()), id: \.offset) { _, c in
                        Rectangle().fill(c).frame(width: 15, height: 26)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))

                Text(theme.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textHi)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.amber : Theme.textDim)
            }
            .padding(10)
            .background(selected ? Theme.amberFillLo : Theme.fill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                .stroke(selected ? Theme.amberBorder : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Use the \(theme.label) theme")
    }
}

private struct PresetSettingsRow: View {
    @Bindable var preset: Preset
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Preset name", text: $preset.name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                Spacer(minLength: 8)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this preset")
            }

            FieldGroup(caption: "System prompt (optional)") {
                TextField("Leave blank to keep the chat's own prompt",
                          text: Binding(get: { preset.systemPrompt ?? "" },
                                        set: { preset.systemPrompt = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .fieldChrome(focused: false)
            }

            SamplingControls(params: Binding(get: { preset.sampling },
                                             set: { preset.sampling = $0 }))
        }
        .padding(14)
        .panel(Theme.fill, radius: Theme.Radius.card, stroke: Theme.line)
    }
}

// MARK: - Section

/// An eyebrow caption above a block of related controls — the recurring
/// settings-group unit.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title)
            content
        }
        // Fill the column and left-align, so a section with narrow content (e.g. a bare
        // toggle) doesn't size-to-fit and float toward the center while wider sections
        // (those with a Spacer) sit flush left.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Server row

/// One LM Studio endpoint as a self-contained module: name header, then a wide
/// host field beside a tight, fixed-width port field. Each field carries its own
/// caption so nothing relies on the title-as-placeholder behavior that broke the
/// old `Form` layout.
private struct ServerSettingsRow: View {
    @Bindable var server: Server
    let onDelete: () -> Void
    @FocusState private var focus: Field?
    @State private var apiKey = ""
    @State private var isKeyRevealed = false
    @State private var needsAuth = false
    @Environment(\.modelContext) private var modelContext
    private let keychain = KeychainStore()
    private var keychainAccount: String { Endpoint.keychainAccount(for: server) }

    private enum Field { case label, host, port, key, agent, prometheus }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Server name", text: $server.label)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .focused($focus, equals: .label)
                Spacer(minLength: 8)
                runtimePicker
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this server")
            }

            // Local runtimes (LM Studio, llama.cpp/llama-swap) are all addressed by host:port.
            HStack(alignment: .bottom, spacing: 12) {
                FieldGroup(caption: "Host") {
                    TextField("hostname or IP", text: $server.host)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .host)
                        .fieldChrome(focused: focus == .host)
                        .onSubmit { server.host = Server.normalizedHost(server.host) }
                }

                FieldGroup(caption: "Port") {
                    TextField("0000", value: $server.port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .port)
                        .fieldChrome(focused: focus == .port)
                        .frame(width: 72)
                }
                .fixedSize()
            }

            // Live "is it working?" feedback — re-probes when host/port/runtime/key change.
            ServerProbeRow(server: server, keyHint: apiKey, onNeedsAuth: { needsAuth = $0 })

            // Shown only once the server actually asks for auth (401), or when a key
            // is already set — so the common no-auth case stays uncluttered.
            if needsAuth || !apiKey.isEmpty {
                FieldGroup(caption: "API key") {
                    HStack(spacing: 0) {
                        Group {
                            if isKeyRevealed { TextField("the key this server expects", text: $apiKey) }
                            else { SecureField("the key this server expects", text: $apiKey) }
                        }
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .key)
                        Button { isKeyRevealed.toggle() } label: {
                            Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 10)).foregroundStyle(Theme.textLo).padding(.trailing, 4)
                        }
                        .buttonStyle(.plain)
                        .help(isKeyRevealed ? "Hide key" : "Reveal key")
                    }
                    .fieldChrome(focused: focus == .key)
                }
                .transition(.opacity)
            }

            FieldGroup(caption: "Agent URL") {
                TextField("http://host:9099  ·  optional", text: Binding(
                    get: { server.metricsAgentURL ?? "" },
                    set: { server.metricsAgentURL = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.plain)
                .focused($focus, equals: .agent)
                .fieldChrome(focused: focus == .agent)
            }

            Text("Optional — a modelo-tap GPU agent on this box. Streams VRAM/power/temp to the Status dashboard. See modelo-tap/README.md.")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read this Mac's GPU (macmon)").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                    Text("For a server running on this Apple-Silicon Mac — shows local GPU on Status + the chat inspector. Requires the macmon CLI.")
                        .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PillToggle(isOn: $server.localGPU)
                    .help("Use the local macmon tool for this Mac's GPU metrics")
            }

            FieldGroup(caption: "Prometheus URL") {
                TextField("http://host:8000/metrics  ·  optional", text: Binding(
                    get: { server.prometheusURL ?? "" },
                    set: { server.prometheusURL = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.plain)
                .focused($focus, equals: .prometheus)
                .fieldChrome(focused: focus == .prometheus)
            }

            Text("Optional — a backend's Prometheus /metrics (vLLM, llama.cpp, llama-swap). Shows running/queued requests and KV-cache use on the Status dashboard.")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: - Context Window (§7)

            SettingsSection("Context Window") {
                Text("Per-model context lengths. Set when the API doesn't report `max_context_length` (e.g. llama-swap, /v1/models fallback). The chat's context bar reads these first.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                if server.contextLengthOverrides.isEmpty {
                    Button(action: addContextWindow) {
                        Label("Add Context Window", systemImage: "plus")
                            .font(Theme.metric(12))
                            .foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    List {
                        ForEach(server.contextLengthOverrides) { override in
                            contextWindowRow(override)
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: CGFloat(min(server.contextLengthOverrides.count, 6) * 44 + 8))

                    Button(action: addContextWindow) {
                        Label("Add Context Window", systemImage: "plus")
                            .font(Theme.metric(12))
                            .foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .panel(Theme.popoverBG)
        // Also normalize when focus leaves the host field (clicking away doesn't
        // fire .onSubmit), so the stored host is cleaned whichever way it's committed.
        .onChange(of: focus) { old, new in
            if old == .host, new != .host {
                server.host = Server.normalizedHost(server.host)
            }
        }
        .onAppear { apiKey = keychain.get(account: keychainAccount) ?? "" }
        .onChange(of: apiKey) { _, newValue in
            keychain.set(newValue.isEmpty ? nil : newValue, account: keychainAccount)
        }
        .onChange(of: server.kind) { _, _ in
            // Defense-in-depth: changing the runtime must not carry a stale bearer token
            // to the new endpoint. Drop any stored key so it can't be silently reused
            // (see the requiresAuth-flag issue for the fuller fix).
            keychain.set(nil, account: keychainAccount)
            apiKey = ""
            needsAuth = false
        }
    }

    // MARK: - Context Window helpers

    private func addContextWindow() {
        // Pre-populate with the most common model ID from recent conversations on this server
        let availableModels = modelsForServer(server.id)
        let suggestedModelID = availableModels.first ?? ""
        let override = ModelContextOverride(
            modelID: suggestedModelID,
            contextLength: suggestedModelID.isEmpty ? 32768 : 131072
        )
        server.contextLengthOverrides.append(override)   // sets the `server` relationship
        try? modelContext.save()
    }

    /// Returns unique model IDs from conversations for the given server, sorted by frequency (most common first).
    private func modelsForServer(_ serverID: UUID) -> [String] {
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.serverID == serverID }
        )
        guard let conversations = try? modelContext.fetch(descriptor) else { return [] }

        // Count occurrences of each model ID
        var counts: [String: Int] = [:]
        for conv in conversations {
            guard !conv.modelID.isEmpty else { continue }
            counts[conv.modelID, default: 0] += 1
        }

        // Sort by frequency (most common first), then alphabetically
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
    }

    private func contextWindowRow(_ override: ModelContextOverride) -> some View {
        let availableModels = modelsForServer(server.id)

        return HStack(spacing: 8) {
            if availableModels.isEmpty {
                // Fallback to text field if no models found in conversations
                TextField("Model ID", text: Binding<String>(
                    get: { override.modelID },
                    set: { override.modelID = $0 }
                ))
                .textFieldStyle(.plain)
                .font(Theme.metric(11))
                .foregroundStyle(override.modelID.isEmpty ? Theme.textFaint : Theme.textHi)
                .frame(maxWidth: 180)
            } else {
                Picker("", selection: Binding<String>(
                    get: { override.modelID },
                    set: { override.modelID = $0 }
                )) {
                    ForEach(availableModels, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .labelsHidden()
            }

            TextField("Tokens", value: Binding<Int>(
                get: { override.contextLength },
                set: { override.contextLength = $0 }
            ), format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.amber)
            .frame(width: 90)

            Spacer(minLength: 0)

            Button(action: {
                server.contextLengthOverrides.removeAll(where: { $0.id == override.id })
                try? modelContext.save()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.alert.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove context window")
        }
        .padding(.vertical, 4)
    }

    /// Runtime selector styled as a chip. Lists the local runtimes only
    /// (LM Studio, llama.cpp); cloud endpoints use a separate tab.
    private var runtimePicker: some View {
        Menu {
            Picker("Runtime", selection: $server.kind) {
                ForEach(ServerKind.localCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        } label: {
            Chip(text: server.kind.displayName.lowercased())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Runtime")
    }
}

// MARK: - Connection probe

/// Live connection feedback for a local server row (#4): probes the endpoint's model
/// list whenever host/port/runtime change and reports "Connected · N models", an
/// error, or a manual re-check — so adding a server gives a clear "it's working"
/// signal instead of silent auto-save.
private struct ServerProbeRow: View {
    let server: Server
    /// The current key text — only used to re-probe when it changes (the request
    /// itself reads the key from the Keychain via `Endpoint`).
    var keyHint: String = ""
    /// Reports whether the server answered with a 401/403, so the parent row can
    /// reveal the API-key field exactly when it's needed.
    var onNeedsAuth: (Bool) -> Void = { _ in }

    @State private var state: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle, checking, ok(Int), needsKey, failed(String)
    }

    /// Re-probe whenever the connection-defining fields (or the key) change.
    private var probeKey: String { "\(server.host)|\(server.port)|\(server.kindRaw)|\(keyHint)" }

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Spacer(minLength: 0)
            Button("Test") { Task { await probe(debounce: false) } }
                .buttonStyle(.plain)
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textDim)
                .help("Re-check this server's connection")
                .disabled(state == .checking)
        }
        .task(id: probeKey) { await probe(debounce: true) }
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .idle, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(Theme.metric(11)).foregroundStyle(Theme.textFaint)
            }
        case .ok(let n):
            Label("Connected · \(n) model\(n == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(Theme.metric(11)).foregroundStyle(Theme.green)
        case .needsKey:
            Label("Connected — needs an API key", systemImage: "key.fill")
                .font(Theme.metric(11)).foregroundStyle(Theme.amber)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.metric(11)).foregroundStyle(Theme.Palette.alert)
                .lineLimit(2)
        }
    }

    private func probe(debounce: Bool) async {
        // Debounce typing so we don't probe on every keystroke; manual Test skips it.
        if debounce { try? await Task.sleep(for: .milliseconds(500)) }
        if Task.isCancelled { return }
        guard !server.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .idle
            onNeedsAuth(false)   // clear a stale "needs key" reveal when the host is emptied
            return
        }
        state = .checking
        let endpoint = Endpoint(server: server, keychain: KeychainStore())
        do {
            let models = try await LMStudioClient.shared.fetchModels(endpoint: endpoint)
            if Task.isCancelled { return }
            state = .ok(models.count)
            onNeedsAuth(false)
        } catch {
            if Task.isCancelled { return }
            if case ClientError.authRequired = error {
                state = .needsKey
                onNeedsAuth(true)              // reveal the key field
            } else {
                let msg = (error as? ClientError)?.errorDescription ?? "Couldn't reach this server."
                state = .failed(msg)
                onNeedsAuth(false)
            }
        }
    }
}

// MARK: - Cloud server row

/// One cloud API endpoint: a user-supplied base URL + a bearer token from Keychain.
/// The `host` field on the `Server` model stores the full base URL for cloud kind.
private struct CloudServerSettingsRow: View {
    @Bindable var server: Server
    let keychain: KeychainStore
    let onDelete: () -> Void

    @State private var apiKey = ""
    @State private var isKeyRevealed = false
    @FocusState private var focus: Field?

    private enum Field { case label, url, key }
    private var keychainAccount: String { Endpoint.keychainAccount(for: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Server name", text: $server.label)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .focused($focus, equals: .label)
                Spacer(minLength: 8)
                Chip(text: "cloud api")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this endpoint")
            }

            FieldGroup(caption: "Base URL") {
                TextField("https://api.together.xyz/v1", text: $server.host)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .url)
                    .fieldChrome(focused: focus == .url)
            }

            FieldGroup(caption: "API Key") {
                HStack(spacing: 0) {
                    Group {
                        if isKeyRevealed {
                            TextField("sk-…", text: $apiKey)
                        } else {
                            SecureField("sk-…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .key)

                    Button { isKeyRevealed.toggle() } label: {
                        Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textLo)
                            .padding(.trailing, 4)
                    }
                    .buttonStyle(.plain)
                    .help(isKeyRevealed ? "Hide key" : "Reveal key")
                }
                .fieldChrome(focused: focus == .key)
            }

            Text("Bearer token — stored in your Keychain. Models load once a valid key is set.")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .panel(Theme.popoverBG)
        .onAppear { apiKey = keychain.get(account: keychainAccount) ?? "" }
        .onChange(of: apiKey) { _, newValue in
            keychain.set(newValue.isEmpty ? nil : newValue, account: keychainAccount)
        }
    }
}

// MARK: - Key card

/// A Keychain-backed secure field with a caption and helper line, in a panel.
/// Local @State mirrors the stored value so typing is smooth; commits on change.
private struct KeyCard: View {
    let caption: String
    let placeholder: String
    let hint: String
    let account: String
    let keychain: KeychainStore

    @State private var key = ""
    @State private var isRevealed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldGroup(caption: caption) {
                HStack(spacing: 0) {
                    Group {
                        if isRevealed {
                            TextField(placeholder, text: $key)
                        } else {
                            SecureField(placeholder, text: $key)
                        }
                    }
                    .textFieldStyle(.plain)
                    .focused($focused)

                    Button { isRevealed.toggle() } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textLo)
                            .padding(.trailing, 4)
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "Hide key" : "Reveal key")
                }
                .fieldChrome(focused: focused)
            }
            Text(hint)
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .panel(Theme.popoverBG)
        .onAppear { key = keychain.get(account: account) ?? "" }
        .onChange(of: key) { _, newValue in
            keychain.set(newValue.isEmpty ? nil : newValue, account: account)
        }
    }
}

// MARK: - Field chrome

/// A captioned field wrapper: a tiny eyebrow over its content, left-aligned and
/// expanding to fill available width.
private struct FieldGroup<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    init(caption: String, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(caption, size: 9)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The shared input look: monospaced text on a sunken near-black field with a
    /// hairline border that lights up amber on focus. Used across Settings and the
    /// shared `SamplingControls`.
    func fieldChrome(focused: Bool) -> some View {
        modifier(FieldChrome(focused: focused))
    }
}

private struct FieldChrome: ViewModifier {
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
                    .strokeBorder(focused ? Theme.amber.opacity(0.85)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            )
            .animation(.snappy(duration: 0.2), value: focused)
    }
}

// MARK: - MCP server row

/// One MCP server configuration: name, enable toggle, command, arguments,
/// and an optional error banner when the last connection attempt failed.
private struct MCPServerSettingsRow: View {
    var config: MCPServerConfig
    let error: String?
    let onUpdate: (MCPServerConfig) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var command: String
    @State private var argsString: String  // space-joined arguments
    @State private var envValues: [String: String]
    @State private var isEnabled: Bool
    @FocusState private var focus: Field?
    @FocusState private var envFocused: String?

    private enum Field { case name, command, args }

    init(config: MCPServerConfig, error: String?,
         onUpdate: @escaping (MCPServerConfig) -> Void,
         onDelete: @escaping () -> Void) {
        self.config   = config
        self.error    = error
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _name       = State(initialValue: config.name)
        _command    = State(initialValue: config.command)
        _argsString = State(initialValue: config.arguments.joined(separator: " "))
        _envValues  = State(initialValue: config.env)
        _isEnabled  = State(initialValue: config.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row
            HStack(spacing: 8) {
                PillToggle(isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, v in commit(enabled: v) }
                    .help(isEnabled ? "Disable server" : "Enable server")
                TextField("Server name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .focused($focus, equals: .name)
                    .onSubmit { commit() }
                Spacer(minLength: 8)
                // Connection status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .help(statusHelp)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove MCP server")
            }

            HStack(alignment: .bottom, spacing: 12) {
                FieldGroup(caption: "Command") {
                    TextField("npx", text: $command)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .command)
                        .fieldChrome(focused: focus == .command)
                        .frame(width: 80)
                        .onSubmit { commit() }
                }
                .fixedSize()
                FieldGroup(caption: "Arguments") {
                    TextField("-y @modelcontextprotocol/server-filesystem /path", text: $argsString)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .args)
                        .fieldChrome(focused: focus == .args)
                        .onSubmit { commit() }
                }
            }

            if !envValues.isEmpty {
                ForEach(envValues.keys.sorted(), id: \.self) { key in
                    EnvKeyField(
                        caption: key,
                        value: Binding(
                            get: { envValues[key] ?? "" },
                            set: { envValues[key] = $0; commit() }
                        ),
                        focused: $envFocused,
                        focusKey: key
                    )
                }
            }

            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.alert)
                    Text(error)
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.Palette.alert)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .panel(Theme.popoverBG)
        .onChange(of: focus) { old, new in
            if old != nil, new == nil { commit() }
        }
        .onChange(of: envFocused) { _, new in
            if new == nil { commit() }
        }
    }

    private var statusColor: Color {
        guard isEnabled else { return Theme.textFaint }
        return error == nil ? Theme.green : Theme.Palette.alert
    }

    private var statusHelp: String {
        guard isEnabled else { return "Disabled" }
        if let error { return "Error: \(error)" }
        return "Connected"
    }

    private func commit(enabled: Bool? = nil) {
        var updated = config
        updated.name      = name.trimmingCharacters(in: .whitespaces).isEmpty ? config.name : name
        updated.command   = command.trimmingCharacters(in: .whitespaces).isEmpty ? config.command : command
        updated.arguments = argsString
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        updated.env       = envValues
        updated.isEnabled = enabled ?? isEnabled
        onUpdate(updated)
    }
}

// MARK: - Env key field

/// A labeled secure field for a single environment variable. Used inside
/// `MCPServerSettingsRow` for API-key-needing servers (e.g. GITHUB_PERSONAL_ACCESS_TOKEN).
private struct EnvKeyField: View {
    let caption: String
    @Binding var value: String
    var focused: FocusState<String?>.Binding
    let focusKey: String

    @State private var isRevealed = false

    var body: some View {
        FieldGroup(caption: caption) {
            HStack(spacing: 0) {
                Group {
                    if isRevealed {
                        TextField("Paste your key", text: $value)
                    } else {
                        SecureField("Paste your key", text: $value)
                    }
                }
                .textFieldStyle(.plain)
                .focused(focused, equals: focusKey)

                Button { isRevealed.toggle() } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textLo)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide key" : "Reveal key")
            }
            .fieldChrome(focused: focused.wrappedValue == focusKey)
        }
    }
}

// MARK: - MCP discovery

/// Browse the bundled catalog of known MCP servers and add one in a single click.
/// Adding hands a ready-to-run `MCPServerConfig` to the manager (disabled), so the
/// user can set any path or key and then enable it. Entries already configured are
/// hidden so the same server can't be added twice.
private struct MCPDiscoverySection: View {
    let installed: [MCPServerConfig]
    let onAdd: (MCPCatalogEntry) -> Void

    private let catalog = BundledMCPCatalog()
    @State private var entries: [MCPCatalogEntry] = []
    @State private var query = ""
    @State private var category = "All"
    @FocusState private var searchFocused: Bool

    /// "All" plus each catalog category in first-seen order.
    private var categories: [String] {
        var seen = Set<String>()
        let ordered = entries.map(\.category).filter { seen.insert($0).inserted }
        return ["All"] + ordered
    }

    /// Apply the category filter and search query, and hide already-installed
    /// servers (matched on the exact command + arguments they'd be added with).
    private var visible: [MCPCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            (category == "All" || entry.category == category)
            && (q.isEmpty || entry.searchText.contains(q))
            && !installed.contains { $0.command == entry.command && $0.arguments == entry.arguments }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Discover")

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search MCP servers", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .fieldChrome(focused: searchFocused)

            // Category filter chips
            if categories.count > 2 {
                HStack(spacing: 7) {
                    ForEach(categories, id: \.self) { cat in
                        CategoryChip(label: cat, active: cat == category) { category = cat }
                    }
                }
            }

            // Results
            if visible.isEmpty {
                Text(emptyMessage)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 6)
            } else {
                ForEach(visible) { entry in
                    CatalogEntryRow(entry: entry) { onAdd(entry) }
                }
            }
        }
        .task { entries = await catalog.load() }
    }

    private var emptyMessage: String {
        if entries.isEmpty { return "Loading catalog…" }
        if !query.isEmpty  { return "No servers match “\(query)”." }
        return "Every catalog server is already installed."
    }
}

/// A small pill that filters the catalog by category. Mirrors the app's chip look.
private struct CategoryChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(Theme.label(9))
                .tracking(0.8)
                .foregroundStyle(active ? Theme.amber : Theme.textLo)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Theme.amber.opacity(0.15) : Theme.fillHi,
                            in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Theme.amber.opacity(0.5)
                                                       : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Filter by \(label)")
    }
}

/// One discoverable server: name, summary, the command it will run, an optional
/// setup hint, and a one-click Add.
private struct CatalogEntryRow: View {
    let entry: MCPCatalogEntry
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                Text(entry.summary)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = setupHint {
                    Label(hint, systemImage: setupIcon)
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.amber)
                }
                Text(commandLine)
                    .font(Theme.code(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onAdd) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add")
                        .font(Theme.label(11))
                }
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .panel(Theme.fillHi, radius: 8, stroke: Theme.amber.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help("Add \(entry.name)")
        }
        .padding(14)
        .panel(Theme.popoverBG)
    }

    private var commandLine: String { ([entry.command] + entry.arguments).joined(separator: " ") }

    private var setupHint: String? {
        switch entry.setup {
        case .none:               return nil
        case .needsPath:          return "Set a path in Arguments before enabling"
        case .needsKey(let env):  return "Needs \(env)"
        }
    }

    private var setupIcon: String {
        switch entry.setup {
        case .none:      return ""
        case .needsPath: return "folder"
        case .needsKey:  return "key.fill"
        }
    }
}
