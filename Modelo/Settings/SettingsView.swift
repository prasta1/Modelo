import SwiftUI
import SwiftData
import AppKit

/// Server management: edit LM Studio host/port, and paste the OpenRouter and
/// Firecrawl API keys (stored in Keychain, not SwiftData).
///
/// Built as a bespoke instrument-panel layout rather than a `.grouped` `Form`:
/// on macOS a `Form` renders each `TextField`'s title as a visible inline label,
/// which collided with the host/port fields and the section labels and broke the
/// layout. Hand-laying the rows gives full control of the chrome and matches the
/// app's monospaced "telemetry" look.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(MCPServerManager.self) private var mcpManager
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    private let keychain = KeychainStore()

    private var lmStudioServers: [Server] { servers.filter { $0.kind == .lmStudio } }
    private var openRouterServers: [Server] { servers.filter { $0.kind == .openRouter } }

    var body: some View {
        TabView {
            // MARK: Servers
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(lmStudioServers) { server in
                        ServerSettingsRow(server: server) {
                            context.delete(server)
                            try? context.save()
                        }
                    }
                    addButton("Add Server", action: addServer)
                }
                .padding(24)
            }
            .tabItem { Label("Servers", systemImage: "network") }

            // MARK: OpenRouter
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(openRouterServers) { server in
                        KeyCard(caption: "API key",
                                placeholder: "sk-or-…",
                                hint: "Stored in your Keychain. Models load once a valid key is set.",
                                account: Endpoint.keychainAccount(for: server),
                                keychain: keychain)
                    }
                }
                .padding(24)
            }
            .onAppear { ensureOpenRouterServer() }
            .tabItem { Label("OpenRouter", systemImage: "globe") }

            // MARK: Personas
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
            .tabItem { Label("Personas", systemImage: "theatermasks") }

            // MARK: Tools
            ScrollView {
                VStack(spacing: 12) {
                    KeyCard(caption: "Firecrawl API key",
                            placeholder: "fc-…",
                            hint: "Enables firecrawl_scrape and firecrawl_search for tool-capable models.",
                            account: FirecrawlClient.keychainAccount,
                            keychain: keychain)
                }
                .padding(24)
            }
            .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            // MARK: MCP Servers
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
            .tabItem { Label("MCP Servers", systemImage: "terminal") }
        }
        .frame(width: 600, height: 460)
        .background(Theme.windowBG)
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
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
    }

    private func addMCPServer() {
        mcpManager.addConfig(MCPServerConfig(
            name: "New MCP Server",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/"],
            isEnabled: false
        ))
    }

    /// Creates the OpenRouter server record if it was somehow deleted.
    /// Under normal operation it is seeded on first launch; this is a safety net.
    private func ensureOpenRouterServer() {
        guard openRouterServers.isEmpty else { return }
        let order = (servers.map(\.sortOrder).max() ?? 0) + 1
        context.insert(Server(label: "OpenRouter", host: "", port: 0, sortOrder: order, kind: .openRouter))
        try? context.save()
    }

    private func addServer() {
        let nextOrder = (lmStudioServers.map(\.sortOrder).max() ?? 0) + 1
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

    private enum Field { case name, icon, tagline, prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon preview + name field + delete
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
                Spacer(minLength: 8)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete persona")
            }

            HStack(spacing: 12) {
                FieldGroup(caption: "Icon (SF Symbol)") {
                    TextField("e.g. brain", text: $persona.icon)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .icon)
                        .fieldChrome(focused: focus == .icon)
                        .frame(width: 140)
                }
                FieldGroup(caption: "Tagline") {
                    TextField("Brief descriptor", text: $persona.tagline)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .tagline)
                        .fieldChrome(focused: focus == .tagline)
                }
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
                    .animation(.easeOut(duration: 0.15), value: focus == .prompt)
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

    private enum Field { case label, host, port }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Server name", text: $server.label)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .focused($focus, equals: .label)
                Spacer(minLength: 8)
                Chip(text: server.kind == .lmStudio ? "lm studio" : "openrouter")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove this server")
            }

            if server.kind == .lmStudio {
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

private extension View {
    /// The shared input look: monospaced text on a sunken near-black field with a
    /// hairline border that lights up amber on focus.
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
            .animation(.easeOut(duration: 0.15), value: focused)
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

    private let catalog: MCPCatalogSource = BundledMCPCatalog()
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
