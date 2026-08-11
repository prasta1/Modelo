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
    @Environment(\.modelContext) private var context
    @Environment(MCPServerManager.self) private var mcpManager
    @Environment(SettingsNavigator.self) private var navigator
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    private let keychain = KeychainStore()
    @SceneStorage("settingsSelectedTab") private var selectedTab = "Endpoints"
    @State private var newlyAddedID: UUID?

    private static let tabTitles = ["Endpoints",
                                    "Presets", "Appearance", "Tools", "Memory", "MCP Servers"]

    private struct CloudPreset: Identifiable {
        var id: String { name }
        let name: String
        let baseURL: String
    }
    private static let cloudPresets: [CloudPreset] = [
        .init(name: "OpenAI",     baseURL: "https://api.openai.com/v1"),
        .init(name: "Groq",       baseURL: "https://api.groq.com/openai/v1"),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        .init(name: "Together",   baseURL: "https://api.together.xyz/v1"),
        .init(name: "DeepSeek",   baseURL: "https://api.deepseek.com/v1"),
        .init(name: "Mistral",    baseURL: "https://api.mistral.ai/v1"),
    ]

    var body: some View {
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
                case "Presets":     PresetsSettingsTab()
                case "Appearance":  AppearanceSettingsTab()
                case "Tools":       toolsTab
                case "Memory":      memoryTab
                case "MCP Servers": mcpServersTab
                default:            endpointsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBG)
        .tint(Theme.amber)
        .preferredColorScheme(Theme.active.scheme)
        // One-shot tab deep link ("Manage models" → Endpoints). A plain ⌘, or
        // sidebar visit has no pending tab and keeps the last selection.
        .onAppear {
            if let tab = navigator.consumeTab() { selectedTab = tab }
        }
    }

    // MARK: Endpoints

    @ViewBuilder
    private func endpointRow(for server: Server) -> some View {
        if server.kind.isLocal {
            ServerSettingsRow(server: server,
                              onDelete: {
                context.delete(server)
                context.saveOrLog()
            }, autoExpand: server.id == newlyAddedID)
        } else {
            CloudServerSettingsRow(server: server, keychain: keychain,
                                   onDelete: {
                context.delete(server)
                context.saveOrLog()
            }, autoExpand: server.id == newlyAddedID)
        }
    }

    private var endpointsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(servers) { server in
                        endpointRow(for: server)
                            .id(server.id)
                    }
                    // Local fans out to per-runtime presets; Cloud API fans out to provider presets.
                    Menu {
                        Menu("Local") {
                            ForEach(ServerKind.localCases, id: \.self) { kind in
                                Button { addLocalServer(kind: kind) } label: {
                                    Label(kind.displayName, systemImage: localIcon(for: kind))
                                }
                            }
                        }
                        Menu("Cloud API") {
                            Button("Nous Research") { addNousServer() }
                            Divider()
                            ForEach(Self.cloudPresets) { preset in
                                Button(preset.name) {
                                    addCloudServer(label: preset.name, baseURL: preset.baseURL)
                                }
                            }
                            Divider()
                            Button("Custom…") { addCloudServer() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Add Endpoint")
                                .font(Theme.label(11))
                        }
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .panel(Theme.popoverBG, radius: 9,
                               stroke: Theme.amber.opacity(0.3))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                .padding(24)
                .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)
            .clipped()
            .onChange(of: newlyAddedID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    // MARK: Tools
    private var toolsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                GlobalToolsCard()
                FilesystemToolsCard()
                ToolRoundsCard()
                YoloCard()
                ArtifactsCard()
                KeyCard(caption: "Firecrawl API key",
                        placeholder: "fc-…",
                        hint: "Enables firecrawl_scrape and firecrawl_search for tool-capable models.",
                        account: FirecrawlClient.keychainAccount,
                        keychain: keychain)
            }
            .padding(24)
            .hideScrollIndicators()
        }
        .scrollIndicators(.hidden)
        .clipped()
    }

    // MARK: Memory

    /// Master toggle on top (off by default — one-off chats stay one-off), the
    /// global-scope memory manager below. The manager stays usable while disabled
    /// so stored memories can still be reviewed and cleaned up.
    private var memoryTab: some View {
        VStack(spacing: 0) {
            MemoryEnableCard()
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            Divider().overlay(Theme.line)
            MemoryManagerView(scope: .global)
        }
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
            .hideScrollIndicators()
        }
        .scrollIndicators(.hidden)
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

    private func addCloudServer(label: String = "Cloud API", baseURL: String = "") {
        let nextOrder = (servers.map(\.sortOrder).max() ?? 0) + 1
        let server = Server(label: label, host: baseURL, port: 0, sortOrder: nextOrder, kind: .cloudAPI)
        context.insert(server)
        context.saveOrLog()
        newlyAddedID = server.id
    }

    private func addNousServer() {
        let nextOrder = (servers.map(\.sortOrder).max() ?? 0) + 1
        let server = Server(label: "Nous Research", host: "", port: 0, sortOrder: nextOrder, kind: .nous)
        context.insert(server)
        context.saveOrLog()
        newlyAddedID = server.id
    }

    private func addLocalServer(kind: ServerKind = .lmStudio) {
        let nextOrder = (servers.map(\.sortOrder).max() ?? 0) + 1
        let server = Server(label: kind.displayName, host: "localhost",
                            port: kind.defaultPort, sortOrder: nextOrder, kind: kind)
        context.insert(server)
        context.saveOrLog()
        newlyAddedID = server.id
    }

    private func localIcon(for kind: ServerKind) -> String {
        switch kind {
        case .lmStudio:                    return "server.rack"
        case .llamaCpp:                    return "terminal"
        case .llamaSwap:                   return "shuffle"
        case .oMLX:                        return "cpu"
        case .ollama:                      return "cylinder"
        case .exo:                         return "point.3.connected.trianglepath.dotted"
        case .cloudAPI, .openRouter, .nous: return "server.rack"
        }
    }

}

// MARK: - Preset list row (right column)

private struct PresetListRow: View {
    let preset: Preset
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name.isEmpty ? "Unnamed" : preset.name)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                let summary = presetSummary
                if !summary.isEmpty {
                    Text(summary)
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
            .help("Delete preset")
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

    private var presetSummary: String {
        let s = preset.sampling
        var parts: [String] = []
        if let t = s.temperature { parts.append(String(format: "temp %.1f", t)) }
        if let k = s.maxTokens { parts.append(k >= 1000 ? "\(k / 1000)k" : "\(k)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Presets (§1.4b)

/// Master-detail layout: editor on the left, saved-presets side menu on the right.
/// `selectedPresetID == nil` means "Generation defaults" is selected.
private struct PresetsSettingsTab: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @AppStorage("globalSamplingJSON") private var json = "{}"
    @State private var params = SamplingParams()
    @State private var selectedPresetID: Preset.ID?

    var body: some View {
        HStack(spacing: 0) {
            // Left: editor
            Group {
                if let selected = presets.first(where: { $0.id == selectedPresetID }) {
                    PresetEditPane(preset: selected)
                        .id(selected.id)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Applied to every conversation unless it overrides them. A disabled control isn't sent — the server uses its own default.")
                                .font(Theme.metric(10))
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                            SamplingControls(params: $params)
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.line)

            // Right: side menu
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .foregroundStyle(selectedPresetID == nil ? Theme.amber : Theme.textMute)
                        .frame(width: 18)
                    Text("Generation defaults")
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    selectedPresetID == nil ? Theme.amber.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selectedPresetID == nil ? Theme.amber.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedPresetID = nil }

                Divider().overlay(Theme.line).padding(.vertical, 8)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(presets) { preset in
                            PresetListRow(
                                preset: preset,
                                isSelected: preset.id == selectedPresetID,
                                onTap: { selectedPresetID = preset.id },
                                onDelete: {
                                    let deletingSelected = preset.id == selectedPresetID
                                    context.delete(preset)
                                    context.saveOrLog()
                                    if deletingSelected { selectedPresetID = nil }
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)

                Button(action: addPreset) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add Preset")
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

                Text("Apply from the sliders button in a chat header.")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(width: 240)
        }
        .onAppear {
            params = (try? JSONDecoder().decode(SamplingParams.self, from: Data(json.utf8))) ?? SamplingParams()
        }
        .onChange(of: params) { _, new in
            json = String(decoding: (try? JSONEncoder().encode(new)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    private func addPreset() {
        let preset = Preset(name: "New Preset", sortOrder: presets.count)
        context.insert(preset)
        context.saveOrLog()
        selectedPresetID = preset.id
    }
}

// MARK: - Preset edit pane (left column)

private struct PresetEditPane: View {
    @Bindable var preset: Preset
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FieldGroup(caption: "Name") {
                    TextField("Preset name", text: $preset.name)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .focused($nameFocused)
                        .fieldChrome(focused: nameFocused)
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

                Eyebrow("Sampling", size: 9)
                SamplingControls(params: Binding(get: { preset.sampling },
                                                 set: { preset.sampling = $0 }))
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
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
                Text("Higher allows more complex multi-step tool use but can run longer. Applies to new chats immediately; open chats update live. Ignored while YOLO mode is on.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Global YOLO mode: auto-approves every mutating tool call and lifts the
/// tool-round cap. `ChatView` observes the same key and ORs it with the
/// per-conversation switch to drive `ChatSession.yoloMode`.
private struct YoloCard: View {
    @AppStorage("yoloModeEnabled") private var enabled = false

    var body: some View {
        SettingsSection("YOLO mode") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-approve all tool calls").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                        Text("Writes, edits and shell commands run without asking, and the tool-call limit is removed.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                Text("The model can modify files and run commands unattended until it finishes or you press Stop. Only use in workspaces you trust. Can also be enabled per chat.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.Palette.alert)
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

/// Opt-in switch for persistent memory. When off, nothing is injected into any
/// prompt and the memory tools aren't registered — zero context cost.
private struct MemoryEnableCard: View {
    @AppStorage(MemoryStore.enabledKey) private var enabled = false

    var body: some View {
        SettingsSection("Memory") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember facts across conversations").font(Theme.metric(12)).foregroundStyle(Theme.textHi)
                        Text("Models can save durable facts with save_memory and see a compact index of them in every chat. Project chats also get project-scoped memories.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .toggleStyle(.switch)
                Text("Off by default — one-off conversations stay one-off. Costs a line of context per memory. Open chats pick the change up from their next message.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
            }
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
            .hideScrollIndicators()
        }
        .scrollIndicators(.hidden)
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
    var autoExpand: Bool = false
    @FocusState private var focus: Field?
    @State private var apiKey = ""
    @State private var isKeyRevealed = false
    @State private var needsAuth = false
    @State private var isExpanded = false
    @State private var showAdvanced = false
    @Environment(\.modelContext) private var modelContext
    @Environment(ServerRegistry.self) private var registry
    private let keychain = KeychainStore()
    private var keychainAccount: String { Endpoint.keychainAccount(for: server) }

    private enum Field { case label, host, port, key, agent, prometheus }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: always visible — tap to expand/collapse
            HStack(spacing: 8) {
                StatusLED(status: registry.status(for: server))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.label.isEmpty ? "Unnamed" : server.label)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                    Text(verbatim: "\(server.host.isEmpty ? "—" : server.host):\(server.port)")
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 8)
                runtimePicker
                PillToggle(isOn: Binding(get: { !server.isPaused }, set: { server.isPaused = !$0 }))
                    .help(server.isPaused ? "Resume: show this server's models in the picker" : "Pause: hide this server's models from the picker")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this server")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() } }
            .help(isExpanded ? "Collapse server" : "Edit server")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Server name", text: $server.label)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .focused($focus, equals: .label)

                    // Local runtimes (LM Studio, llama.cpp/llama-swap, oMLX) are all addressed by host:port.
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

                    LocalSetupHint(kind: server.kind)

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

                    // Advanced: agent URL, macmon, Prometheus — hidden by default to keep the
                    // common case clean. Auto-expands when any of these fields are already set.
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Advanced")
                                .font(Theme.label(9))
                                .tracking(1.0)
                        }
                        .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        VStack(alignment: .leading, spacing: 14) {
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
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

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
                            .hideScrollIndicators()

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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        .onAppear {
            apiKey = keychain.get(account: keychainAccount) ?? ""
            if autoExpand { isExpanded = true }
            // Auto-reveal Advanced if any advanced fields are already configured.
            if server.metricsAgentURL != nil || server.prometheusURL != nil || server.localGPU {
                showAdvanced = true
            }
        }
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
        modelContext.saveOrLog()
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
                modelContext.saveOrLog()
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

    /// Runtime selector styled as a chip. Lists local runtimes only (via `ServerKind.localCases`);
    /// cloud endpoints use a separate tab.
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
        .onChange(of: server.kind) { _, newKind in reseedDefaults(for: newKind) }
    }

    /// When the user switches runtimes, re-seed the port and label to the new kind's
    /// defaults — but only while they still hold a recognized default, so a hand-typed
    /// port or a renamed server is never clobbered. Keeps a fresh server's host:port and
    /// pill label honest (e.g. picking oMLX lands on :8000 labelled "oMLX").
    private func reseedDefaults(for kind: ServerKind) {
        if ServerKind.isDefaultLocalPort(server.port) {
            server.port = kind.defaultPort
        }
        let defaultLabels = Set(ServerKind.localCases.map(\.displayName) + ["New Server"])
        if defaultLabels.contains(server.label) {
            server.label = kind.displayName
        }
    }
}

// MARK: - Local setup hint

/// A compact callout shown inside an expanded local server row that gives runtime-specific
/// setup steps — install instructions, the key command to start the server, and the
/// default port — so users can get from zero to "Connected" without leaving the app.
private struct LocalSetupHint: View {
    let kind: ServerKind

    var body: some View {
        if !hint.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("Quick setup · \(kind.displayName)", systemImage: "lightbulb")
                    .font(Theme.label(9))
                    .tracking(1.0)
                    .foregroundStyle(Theme.amber.opacity(0.8))
                Text(hint)
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.amber.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.amber.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private var hint: String {
        switch kind {
        case .lmStudio:
            return "Install LM Studio from lmstudio.ai. Load a model in the Models tab, then start the local server from the Developer tab. Default port: 1234."
        case .ollama:
            return "Install Ollama from ollama.com, then pull a model: ollama pull llama3.2. The server starts automatically. Default port: 11434."
        case .llamaCpp:
            return "Run the server: llama-server -m model.gguf --port 8080. Default port: 8080."
        case .llamaSwap:
            return "llama-swap is a reverse proxy that manages multiple llama.cpp backends. Point to your llama-swap host and port (default 8080). See github.com/mostlygeek/llama-swap for setup."
        case .oMLX:
            return "Install oMLX (Apple Silicon) from omlx.ai. Load a model in the app and tap Start Server. Default port: 8000."
        case .exo:
            return "Run exo (exolabs.net) on this or another Mac. Add its host and port (default 52415). Models must be launched in exo's dashboard before you can chat with them."
        case .cloudAPI, .openRouter, .nous:
            return ""
        }
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
    var autoExpand: Bool = false

    @State private var apiKey = ""
    @State private var isKeyRevealed = false
    @State private var isExpanded = false
    @FocusState private var focus: Field?
    @Environment(ServerRegistry.self) private var registry

    private enum Field { case label, url, key }
    private var keychainAccount: String { Endpoint.keychainAccount(for: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: always visible — tap to expand/collapse
            HStack(spacing: 8) {
                StatusLED(status: registry.status(for: server))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.label.isEmpty ? "Unnamed" : server.label)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                    Text(verbatim: server.kind.hasFixedURL ? server.baseURL : (server.host.isEmpty ? "not configured" : server.host))
                        .font(Theme.metric(10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Chip(text: server.kind.displayName.lowercased(), tint: Theme.amber)
                PillToggle(isOn: Binding(get: { !server.isPaused }, set: { server.isPaused = !$0 }))
                    .help(server.isPaused ? "Resume: show this endpoint's models in the picker" : "Pause: hide this endpoint's models from the picker")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this endpoint")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() } }
            .help(isExpanded ? "Collapse endpoint" : "Edit endpoint")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Server name", text: $server.label)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .focused($focus, equals: .label)

                    if server.kind.hasFixedURL {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textFaint)
                            Text(verbatim: server.baseURL)
                                .font(Theme.metric(11))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        FieldGroup(caption: "Base URL") {
                            TextField("https://api.together.xyz/v1", text: $server.host)
                                .textFieldStyle(.plain)
                                .focused($focus, equals: .url)
                                .fieldChrome(focused: focus == .url)
                        }
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .panel(Theme.popoverBG)
        .onAppear {
            apiKey = keychain.get(account: keychainAccount) ?? ""
            if autoExpand { isExpanded = true }
        }
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
struct FieldGroup<Content: View>: View {
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
                            // No commit() here: committing per keystroke persists config and
                            // relaunches the server process per character. Blur/submit commit.
                            set: { envValues[key] = $0 }
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
    private let registry = MCPRegistrySearch()
    @State private var entries: [MCPCatalogEntry] = []
    @State private var query = ""
    @State private var category = "All"
    @FocusState private var searchFocused: Bool

    // Live MCP Registry search state, driven by the same query field.
    @State private var remote: [MCPCatalogEntry] = []
    @State private var searching = false
    @State private var searchFailed = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

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

    /// Registry hits not already installed and not duplicating a bundled entry
    /// (many bundled servers are also published to the registry).
    private var remoteVisible: [MCPCatalogEntry] {
        remote.filter { entry in
            !entries.contains { $0.command == entry.command && $0.arguments == entry.arguments }
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

            // Live results from the official MCP Registry once the query is
            // long enough to be meaningful.
            if trimmedQuery.count >= 2 {
                HStack(spacing: 8) {
                    Eyebrow("MCP Registry")
                    if searching {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    }
                }
                .padding(.top, 6)

                if !remoteVisible.isEmpty {
                    ForEach(remoteVisible) { entry in
                        CatalogEntryRow(entry: entry) { onAdd(entry) }
                    }
                } else if !searching {
                    Text(searchFailed ? "Registry search failed — check your connection."
                                      : "No registry servers match “\(trimmedQuery)”.")
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.vertical, 6)
                }
            }
        }
        .task { entries = await catalog.load() }
        .task(id: query) {
            let q = trimmedQuery
            guard q.count >= 2 else {
                remote = []; searching = false; searchFailed = false
                return
            }
            do {
                // Debounce: typing cancels this task, so superseded queries
                // never reach the network.
                try await Task.sleep(for: .milliseconds(350))
                searching = true
                remote = try await registry.search(q)
                searchFailed = false
            } catch is CancellationError {
                return   // a newer query owns the search state now
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                remote = []
                searchFailed = true
            }
            searching = false
        }
    }

    private var emptyMessage: String {
        if entries.isEmpty { return "Loading catalog…" }
        if !query.isEmpty  { return "No bundled servers match “\(query)”." }
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
        case .needsKey(let envs): return "Needs \(envs.joined(separator: ", "))"
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
