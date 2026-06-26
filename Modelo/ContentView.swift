import SwiftUI
import SwiftData

/// Sidebar navigation destination.
enum SidebarRoute: Hashable {
    case launcher
    case status
    case reports
    case settings
    case conversation(PersistentIdentifier)
    case project(UUID)
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
    @Environment(GPUMonitor.self) private var gpuMonitor
    @Environment(\.modelContext) private var context
    @Environment(ProjectStore.self) private var projectStore
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @State private var route: SidebarRoute?
    /// Owns each conversation's streaming session so a turn keeps running after the
    /// user navigates to another chat — enabling concurrent chats.
    @State private var sessionStore = ChatSessionStore()
    /// Posts reply-finished notifications for chats the user isn't watching; tracks
    /// which conversation is on screen so the foreground chat stays quiet.
    @State private var notifier = ChatNotifier()
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
                        onNewChat: { newChat() },
                        onRenameWithAI: { convo in Task { await renameWithAI(convo) } })
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detailView
                .inspector(isPresented: $inspectorOpen) {
                    inspectorContent
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                        // The console polls GPU/usage stats on a timer, re-rendering this
                        // subtree every tick. Without clearing the animation, SwiftUI re-asserts
                        // the column toward `ideal` on each render and the panel visibly slides
                        // in/out once it has been manually resized away from 300.
                        .transaction { $0.animation = nil }
                }
        }
        .navigationTitle("")
        // Shared across the sidebar and detail so a streaming turn survives chat
        // switches and the sidebar can discard a deleted conversation's session.
        .environment(sessionStore)
        .environment(notifier)
        .preferredColorScheme(Theme.active.scheme)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem {
                Button {
                    inspectorOpen.toggle()
                } label: {
                    Label("Console", systemImage: "chart.bar.xaxis")
                }
                .help("Toggle inference console (⌘I)")
            }
        }
        .task(id: serverDiscoveryKey) {
            selectDefaultEndpoint()
            gpuMonitor.start(servers: servers)   // pick up agent-URL / macmon changes
            await refreshModels()
        }
        .onAppear { restoreRoute(); notifier.requestAuthorization(); updateForeground() }
        .onChange(of: route) { saveRoute(route); syncPickedModel(); updateForeground() }
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
            ServerStatsView(endpointFilter: $endpointFilter)
        case .reports:
            ReportingView()
        case .settings:
            SettingsView(isInline: true)
        case .project(let id):
            if let project = projectStore.projects.first(where: { $0.id == id }) {
                ProjectLandingView(project: project) { proj in newChatInProject(proj) }
            } else {
                launcher
            }
        case .conversation:
            if let convo = selectedConversation {
                ChatView(conversation: convo, discovered: discoveredWithLiveState, pickedModel: $pickedModel, onModelSelect: handleModelSelection, onModelEject: handleModelEject)
                    .id(convo.persistentModelID)
            } else {
                launcher
            }
        }
    }

    private var launcher: some View {
        LauncherView(
            discovered: discoveredWithLiveState,
            endpointFilter: endpointFilter,
            onLaunch: { model, persona in Task { await launch(model: model, persona: persona) } },
            onUnload: handleModelEject,
            onPin: { item in await handleModelPin(server: item.server, modelID: item.model.id) },
            onUnpin: { item in await handleModelUnpin(server: item.server, modelID: item.model.id) },
            onRefresh: { await refreshModels() }
        )
    }

    /// Context tokens used by the active chat — the last turn's server-reported total,
    /// or a live estimate of the active path before the first turn.
    private var inspectorContextUsed: Int {
        guard let convo = selectedConversation else { return 0 }
        return convo.contextTokensUsed ?? TokenEstimator.estimate(convo.activePath())
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let server = pickedModel?.server {
            ConsoleInspector(server: server, activeModel: pickedModel?.model,
                             snapshot: monitor.snapshot(for: server),
                             gpu: gpuMonitor.snapshot(for: server),
                             contextUsed: inspectorContextUsed,
                             contextWindow: pickedModel?.model.maxContextLength ?? 0)
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

    /// Tells the notifier which conversation is on screen, so a reply that finishes
    /// in the chat the user is watching stays quiet (only background chats notify).
    private func updateForeground() {
        if case .conversation(let id) = route {
            notifier.foreground = id
        } else {
            notifier.foreground = nil
        }
    }

    private func saveRoute(_ route: SidebarRoute?) {
        switch route {
        case .launcher:              storedRoute = "launcher"
        case .status:                storedRoute = "status"
        case .reports:               storedRoute = "reports"
        case .settings:              storedRoute = "settings"
        case .project(let id):       storedRoute = "proj:" + id.uuidString
        case .conversation(let id):
            if let data = try? JSONEncoder().encode(id) {
                storedRoute = "conv:" + data.base64EncodedString()
            }
        case nil:                    storedRoute = ""
        }
    }

    private func restoreRoute() {
        guard route == nil else { return }
        if storedRoute.isEmpty {
            route = .status
            return
        }
        switch storedRoute {
        case "launcher":  route = .launcher
        case "status":    route = .status
        case "reports":   route = .reports
        case "settings":  route = .settings
        default:
            if storedRoute.hasPrefix("proj:") {
                let uuidStr = String(storedRoute.dropFirst(5))
                if let uuid = UUID(uuidString: uuidStr) {
                    route = .project(uuid)
                    return
                }
            }
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
                sampling: SamplingParams(temperature: 0.3), tools: nil
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

    /// Re-discover when a server is added/edited/removed (or comes online), not just
    /// when the online set changes — so a newly-configured server's models appear.
    private var serverDiscoveryKey: String {
        servers.map { "\($0.id)|\($0.host)|\($0.port)|\($0.kindRaw)|\(registry.isOnline($0))|\($0.metricsAgentURL ?? "")|\($0.localGPU)" }
            .joined(separator: ",")
    }

    /// Creates a new conversation scoped to a project directory. The project path
    /// is stored on the conversation so filesystem tools can be registered, and a
    /// system prompt tells the model which tools are available and how to use them.
    private func newChatInProject(_ project: Project) {
        let systemPrompt = """
        You are a coding assistant working in the project directory "\(project.name)".

        Project root: \(project.path)

        You have the following filesystem tools available. All paths are relative to the project root.
        - read_file(path) — read a file's text content
        - write_file(path, content) — create or overwrite a file
        - edit_file(path, old_string, new_string, replace_all?) — replace an exact string in a file
        - grep(pattern, path?) — search file contents for a regular expression
        - glob(pattern) — list files matching a glob (e.g. "**/*.swift")

        Start with glob("**/*") or read a specific file to orient yourself before answering questions about the code.
        """
        let convo = Conversation(modelID: pickedModel?.model.id ?? "", serverID: pickedModel?.server.id)
        convo.systemPrompt = systemPrompt
        convo.projectPath = project.path
        context.insert(convo)
        try? context.save()
        route = .conversation(convo.persistentModelID)
    }

    /// `discovered` overlaid with live loaded/keepInRam state from the 3-second monitor poll.
    /// Since `monitor` is @Observable, SwiftUI re-renders the launcher automatically each poll cycle.
    private var discoveredWithLiveState: [DiscoveredModel] {
        discovered.map { item in
            guard item.server.kind == .lmStudio else { return item }
            let snapshot = monitor.snapshot(for: item.server)
            let liveModel = snapshot?.models.first(where: { $0.id == item.model.id })
            var updated = item.model
            if snapshot != nil {
                updated.state = liveModel != nil ? "loaded" : "not-loaded"
                if let live = liveModel { updated.keepInRam = live.keepInRam }
            }
            return DiscoveredModel(server: item.server, model: updated)
        }
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
        // Query every server, not just ones the reachability monitor has already
        // flagged online — a freshly-added/edited server (or one that came up after
        // launch) is "unknown" until its next probe, and we shouldn't hide its models
        // in the meantime. fetchModels fails fast for genuinely-offline servers.
        let targets = servers.map { (server: $0, endpoint: Endpoint(server: $0, keychain: keychain)) }

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

        // A server that just returned a model list is, by definition, reachable —
        // mark it online so its dot turns green without waiting for the next probe.
        for (index, target) in targets.enumerated() where !(modelsByIndex[index] ?? []).isEmpty {
            registry.setStatus(.online, for: target.server)
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

