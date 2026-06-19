import SwiftUI
import SwiftData

/// Sidebar navigation destination.
enum SidebarRoute: Hashable {
    case launcher
    case status
    case reports
    case conversation(PersistentIdentifier)
}

/// Actions the focused main window exposes to the menu bar.
///
/// Menu commands are declared in the `App` scene, separate from `ContentView`'s
/// `@State`. `@FocusedValue` bridges the two: `ContentView` publishes this bundle
/// while its window is frontmost (see `.focusedSceneValue` below), and the menu
/// items call back into it. When no window is focused, the value is `nil` and the
/// items disable themselves.
struct ModeloCommands {
    var newChat: () -> Void
    var goToLauncher: () -> Void
    var goToStatus: () -> Void
    var goToReports: () -> Void
}

private struct ModeloCommandsKey: FocusedValueKey {
    typealias Value = ModeloCommands
}

extension FocusedValues {
    var modeloCommands: ModeloCommands? {
        get { self[ModeloCommandsKey.self] }
        set { self[ModeloCommandsKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @State private var route: SidebarRoute?
    @State private var pickedModel: DiscoveredModel?
    @State private var discovered: [DiscoveredModel] = []
    @State private var endpointFilter: UUID?
    @State private var renamingIDs: Set<PersistentIdentifier> = []
    @AppStorage("consoleInspectorOpen") private var inspectorOpen: Bool = false
    @SceneStorage("sidebarRoute") private var storedRoute: String = ""

    private let client = LMStudioClient.shared
    private let keychain = KeychainStore()

    /// The conversation matching the current sidebar route, if any.
    private var selectedConversation: Conversation? {
        guard case .conversation(let id) = route else { return nil }
        return conversations.first { $0.persistentModelID == id }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(route: $route, endpointFilter: $endpointFilter,
                        renamingIDs: renamingIDs,
                        onRenameWithAI: { convo in Task { await renameWithAI(convo) } })
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detailView
                .inspector(isPresented: $inspectorOpen) {
                    inspectorContent
                }
        }
        .navigationTitle("")
        .preferredColorScheme(.dark)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            // Navigation lives in the sidebar (and the Go menu, ⌘1/2/3); the
            // toolbar carries actions only — create, inspect, configure.
            ToolbarItem {
                Button { newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
            }
            ToolbarItem {
                Button {
                    inspectorOpen.toggle()
                } label: {
                    Label("Console", systemImage: "chart.bar.xaxis")
                }
                .help("Toggle inference console (⌘I)")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .task(id: onlineServerIDs) { selectDefaultEndpoint(); await refreshModels() }
        .onAppear { restoreRoute() }
        .onChange(of: route) { saveRoute(route); syncPickedModel() }
        .focusedSceneValue(\.modeloCommands, ModeloCommands(
            newChat: { newChat() },
            goToLauncher: { route = .launcher; selectDefaultEndpoint() },
            goToStatus: { route = .status },
            goToReports: { route = .reports }
        ))
    }

    // MARK: Detail routing

    @ViewBuilder
    private var detailView: some View {
        switch route {
        case .launcher, nil:
            launcher
        case .status:
            StatusView(
                onPin: { server, modelID in Task { await handleModelPin(server: server, modelID: modelID) } },
                onUnpin: { server, modelID in Task { await handleModelUnpin(server: server, modelID: modelID) } }
            )
        case .reports:
            ReportingView()
        case .conversation:
            if let convo = selectedConversation {
                ChatView(conversation: convo, discovered: discovered, pickedModel: $pickedModel, onModelSelect: handleModelSelection, onModelEject: handleModelEject)
                    .id(convo.persistentModelID)
            } else {
                launcher
            }
        }
    }

    private var launcher: some View {
        LauncherView(
            discovered: discovered,
            endpointFilter: endpointFilter,
            onLaunch: { model, persona in Task { await launch(model: model, persona: persona) } },
            onUnload: handleModelEject,
            onPin: { item in await handleModelPin(server: item.server, modelID: item.model.id) },
            onUnpin: { item in await handleModelUnpin(server: item.server, modelID: item.model.id) }
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let server = pickedModel?.server {
            ConsoleInspector(server: server, activeModel: pickedModel?.model, snapshot: monitor.snapshot(for: server))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.Palette.inkFaint)
                Text("Open a chat (⌘N) and pick a model\nfrom the header to see live metrics.")
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.panel)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
    }

    // MARK: Chat management

    /// Toolbar ⌘N — reuses an existing empty chat or creates a blank one.
    private func newChat() {
        if let blank = conversations.first(where: { $0.messages.isEmpty }) {
            route = .conversation(blank.persistentModelID)
            return
        }
        let convo = Conversation(modelID: pickedModel?.model.id ?? "",
                                 serverID: pickedModel?.server.id)
        context.insert(convo)
        try? context.save()
        route = .conversation(convo.persistentModelID)
    }

    /// Launcher tile tap — creates a chat pre-bound to a model and optional persona.
    private func launch(model: DiscoveredModel, persona: Persona?) async {
        // Load the model first if it's an LM Studio model and not loaded
        if model.server.kind == .lmStudio, !model.model.isLoaded {
            let endpoint = Endpoint(server: model.server, keychain: keychain)
            do {
                _ = try await client.loadModel(modelID: model.model.id, endpoint: endpoint)
                await refreshModels()
            } catch {
                // If loading fails, still proceed - the error will surface in chat
            }
        }
        pickedModel = model
        let convo = Conversation(modelID: model.model.id, serverID: model.server.id)
        if let persona { convo.systemPrompt = persona.systemPrompt }
        context.insert(convo)
        try? context.save()
        route = .conversation(convo.persistentModelID)
    }

    private func syncPickedModel() {
        guard let convo = selectedConversation else { return }
        if let match = discovered.first(where: {
            $0.server.id == convo.serverID && $0.model.id == convo.modelID
        }) {
            pickedModel = match
        }
    }

    private func saveRoute(_ route: SidebarRoute?) {
        switch route {
        case .launcher:              storedRoute = "launcher"
        case .status:                storedRoute = "status"
        case .reports:               storedRoute = "reports"
        case .conversation(let id):
            if let data = try? JSONEncoder().encode(id) {
                storedRoute = "conv:" + data.base64EncodedString()
            }
        case nil:                    storedRoute = ""
        }
    }

    private func restoreRoute() {
        guard route == nil, !storedRoute.isEmpty else { return }
        switch storedRoute {
        case "launcher": route = .launcher
        case "status":   route = .status
        case "reports":  route = .reports
        default:
            guard storedRoute.hasPrefix("conv:") else { return }
            let b64 = String(storedRoute.dropFirst(5))
            guard let data = Data(base64Encoded: b64),
                  let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data),
                  conversations.first(where: { $0.persistentModelID == id }) != nil else { return }
            route = .conversation(id)
        }
    }

    /// Generates a new title for `convo` using the same LLM that served it,
    /// re-running the same prompt used for auto-titling at first exchange.
    private func renameWithAI(_ convo: Conversation) async {
        guard !renamingIDs.contains(convo.persistentModelID) else { return }
        guard let serverID = convo.serverID,
              let server = servers.first(where: { $0.id == serverID }),
              registry.isOnline(server) else { return }

        let opener = convo.messages
            .sorted { $0.createdAt < $1.createdAt }
            .first { $0.role == .user }?.content ?? ""
        guard !opener.isEmpty else { return }

        renamingIDs.insert(convo.persistentModelID)
        defer { renamingIDs.remove(convo.persistentModelID) }

        let prompt = Message(role: .user, content: String(opener.prefix(600)))
        let system = """
        Generate a short, specific title (3 to 6 words) for a conversation that \
        opens with the following message. Reply with ONLY the title — no quotes, \
        no preamble, no trailing punctuation.
        """
        var raw = ""
        do {
            let stream = client.streamChat(
                endpoint: Endpoint(server: server, keychain: keychain),
                modelID: convo.modelID,
                messages: [prompt], systemPrompt: system,
                temperature: 0.3, tools: nil
            )
            for try await event in stream {
                if case .delta(let t) = event { raw += t }
            }
        } catch { return }

        let title = ChatSession.cleanTitle(raw)
        guard !title.isEmpty, convo.modelContext != nil else { return }
        convo.title = title
        try? context.save()
    }

    private var onlineServerIDs: [UUID] {
        servers.filter { registry.isOnline($0) }.map(\.id)
    }

    /// Picks the default endpoint when nothing valid is currently selected.
    /// Prefers the first online server by sortOrder; falls back to the first overall.
    private func selectDefaultEndpoint() {
        if let id = endpointFilter,
           let server = servers.first(where: { $0.id == id }),
           registry.isOnline(server) {
            return
        }
        endpointFilter = (servers.first { registry.isOnline($0) } ?? servers.first)?.id
    }

    private func refreshModels() async {
        let targets = servers.filter { registry.isOnline($0) }
            .map { (server: $0, endpoint: Endpoint(server: $0, keychain: keychain)) }

        var modelsByIndex: [Int: [LMStudioModel]] = [:]
        await withTaskGroup(of: (Int, [LMStudioModel]).self) { group in
            for (index, target) in targets.enumerated() {
                let endpoint = target.endpoint
                group.addTask {
                    (index, (try? await client.fetchModels(endpoint: endpoint)) ?? [])
                }
            }
            for await (index, models) in group { modelsByIndex[index] = models }
        }

        discovered = targets.enumerated().flatMap { index, target in
            (modelsByIndex[index] ?? []).map { DiscoveredModel(server: target.server, model: $0) }
        }
    }

    /// Unloads a model on LM Studio and clears the selection if it was the active model.
    private func handleModelEject(_ item: DiscoveredModel) async {
        let endpoint = Endpoint(server: item.server, keychain: keychain)
        do {
            _ = try await client.unloadModel(modelID: item.model.id, endpoint: endpoint)
            await refreshModels()
            if pickedModel?.model.id == item.model.id {
                pickedModel = nil
            }
        } catch {
            // Silently ignore — state will reconcile on next refresh
        }
    }

    /// Pins a model on LM Studio so it won't be auto-evicted when another model loads.
    private func handleModelPin(server: Server, modelID: String) async {
        let endpoint = Endpoint(server: server, keychain: keychain)
        do {
            try await client.setKeepInRam(modelID: modelID, keepInRam: true, endpoint: endpoint)
            await refreshModels()
        } catch {
            // Silently ignore — state will reconcile on next refresh
        }
    }

    /// Unpins a model on LM Studio so it may be evicted when another model loads.
    private func handleModelUnpin(server: Server, modelID: String) async {
        let endpoint = Endpoint(server: server, keychain: keychain)
        do {
            try await client.setKeepInRam(modelID: modelID, keepInRam: false, endpoint: endpoint)
            await refreshModels()
        } catch {
            // Silently ignore — state will reconcile on next refresh
        }
    }

    /// Handles model selection in the picker: loads the model on LM Studio if needed.
    /// Returns true if selection should proceed, false if loading failed.
    private func handleModelSelection(_ item: DiscoveredModel) async -> Bool {
        // Only LM Studio models support load/unload
        guard item.server.kind == .lmStudio else { return true }

        // Already loaded? Nothing to do.
        if item.model.isLoaded { return true }

        // Load the model
        let endpoint = Endpoint(server: item.server, keychain: keychain)
        do {
            _ = try await client.loadModel(modelID: item.model.id, endpoint: endpoint)
            // Refresh to reflect the new loaded state
            await refreshModels()
            return true
        } catch {
            // Loading failed - don't change selection
            return false
        }
    }
}

// MARK: - Menu bar commands

/// File ▸ New Chat — replaces the default "New Window" item so ⌘N is discoverable
/// in the menu bar, not just bound to the toolbar button.
struct NewChatCommand: View {
    @FocusedValue(\.modeloCommands) private var commands

    var body: some View {
        Button("New Chat") { commands?.newChat() }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(commands == nil)
    }
}

/// Go ▸ jump to the app's main sections from the menu bar (⌘1/⌘2/⌘3).
struct GoCommands: View {
    @FocusedValue(\.modeloCommands) private var commands

    var body: some View {
        Group {
            Button("Models") { commands?.goToLauncher() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Status") { commands?.goToStatus() }
                .keyboardShortcut("2", modifiers: .command)
            Button("Reports") { commands?.goToReports() }
                .keyboardShortcut("3", modifiers: .command)
        }
        .disabled(commands == nil)
    }
}

