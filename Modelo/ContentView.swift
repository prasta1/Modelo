import SwiftUI
import SwiftData

/// Sidebar navigation destination.
enum SidebarRoute: Hashable {
    case launcher
    case personas
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

/// A pending exo model-load awaiting the user's RAM-cost confirmation. Holds the
/// continuation so `launch` can `await` the user's Load/Cancel choice inline.
private struct ExoLoadPrompt: Identifiable {
    let id = UUID()
    let model: DiscoveredModel
    let continuation: CheckedContinuation<Bool, Never>
}

/// Routes every settings entry point — ⌘, (app menu), the sidebar row, and the
/// model picker's "Manage models" — to the in-app settings pane.
///
/// Owned by `ModeloApp` (so the ⌘, menu command can reach it even when no window
/// is focused and `@FocusedValue` would be nil) and injected into the window's
/// environment. Requests are one-shot: `ContentView` consumes `requestID` to set
/// the route, and `SettingsView` consumes `pendingTab` to select a specific tab.
@Observable @MainActor
final class SettingsNavigator {
    /// Non-nil while a settings request awaits routing; a fresh UUID per request
    /// so repeated ⌘, presses are distinguishable.
    private(set) var requestID: UUID?
    /// One-shot tab override for `SettingsView` (e.g. "Endpoints"); nil keeps the
    /// last-selected tab.
    private(set) var pendingTab: String?

    /// Request the settings pane, optionally on a specific tab.
    func open(tab: String? = nil) {
        pendingTab = tab
        requestID = UUID()
    }

    /// True (once) if a request was pending — the caller routes to settings.
    func consumeRequest() -> Bool {
        guard requestID != nil else { return false }
        requestID = nil
        return true
    }

    /// The requested tab (once), if any — the caller selects it.
    func consumeTab() -> String? {
        defer { pendingTab = nil }
        return pendingTab
    }
}

struct ContentView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor
    @Environment(GPUMonitor.self) private var gpuMonitor
    @Environment(ReachabilityMonitor.self) private var reachability
    @Environment(\.modelContext) private var context
    @Environment(ProjectStore.self) private var projectStore
    @Environment(RotationStore.self) private var rotationStore
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @State private var route: SidebarRoute?
    /// Owns each conversation's streaming session so a turn keeps running after the
    /// user navigates to another chat — enabling concurrent chats.
    @State private var sessionStore = ChatSessionStore()
    /// Posts reply-finished notifications for chats the user isn't watching; tracks
    /// which conversation is on screen so the foreground chat stays quiet. Owned by
    /// `ModeloApp` (so its notification delegate outlives this window) and injected.
    @Environment(ChatNotifier.self) private var notifier
    @Environment(SettingsNavigator.self) private var settingsNavigator
    @State private var pickedModel: DiscoveredModel?
    @State private var pendingExoLoad: ExoLoadPrompt?
    @State private var discovered: [DiscoveredModel] = []
    @State private var endpointFilter: UUID?
    @State private var renamingIDs: Set<PersistentIdentifier> = []
    /// This view's own window, resolved from the view hierarchy so screen-clamping
    /// can't target the expanded-table window instead.
    @State private var hostWindow: NSWindow?
    @AppStorage("consoleInspectorOpen") private var inspectorOpen: Bool = false
    /// Observed so flipping Settings ▸ Memory drops all sessions — their memory tools
    /// and index injection are fixed at build, so each chat rebuilds on its next message.
    @AppStorage(MemoryStore.enabledKey) private var memoryEnabled = false
    @SceneStorage("sidebarRoute") private var storedRoute: String = ""

    private let client = LMStudioClient.shared
    private let exoClient = ExoClient()
    private let keychain = KeychainStore()

    /// The conversation matching the current sidebar route, if any.
    private var selectedConversation: Conversation? {
        guard case .conversation(let id) = route else { return nil }
        return conversations.first { $0.persistentModelID == id }
    }

    /// The console inspector shows live model metrics, so it's only meaningful on
    /// chat-style routes. Hidden on Settings / Reports / Status, where it's useless
    /// and (when open) shoves the window off-screen as it grows.
    private var routeSupportsConsole: Bool {
        switch route {
        case .conversation, .launcher, .project, nil: true
        case .status, .reports, .settings, .personas: false
        }
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
        .confirmationDialog(
            "Load model into exo?",
            isPresented: Binding(
                get: { pendingExoLoad != nil },
                set: { presented in
                    // Dismissed without choosing (Esc / click-away) counts as Cancel.
                    if !presented, let prompt = pendingExoLoad {
                        prompt.continuation.resume(returning: false)
                        pendingExoLoad = nil
                    }
                }
            ),
            presenting: pendingExoLoad
        ) { prompt in
            Button("Load") {
                prompt.continuation.resume(returning: true)
                pendingExoLoad = nil
            }
            Button("Cancel", role: .cancel) {
                prompt.continuation.resume(returning: false)
                pendingExoLoad = nil
            }
        } message: { prompt in
            Text("\(prompt.model.model.id) will be loaded into exo and use several GB of RAM until you unload it.")
        }
        .navigationTitle("")
        // Shared across the sidebar and detail so a streaming turn survives chat
        // switches and the sidebar can discard a deleted conversation's session.
        .environment(sessionStore)
        .onChange(of: memoryEnabled) { sessionStore.invalidateSessions() }
        .preferredColorScheme(Theme.active.scheme)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if routeSupportsConsole {
                ToolbarItem {
                    Button {
                        inspectorOpen.toggle()
                    } label: {
                        Label("Console", systemImage: "chart.bar.xaxis")
                    }
                    .help("Toggle inference console (⌘I)")
                }
            }
        }
        .task(id: serverDiscoveryKey) {
            let activeServers = servers.filter { !$0.isPaused }
            gpuMonitor.start(servers: activeServers)   // pick up agent-URL / macmon changes
            // Restart load-state polling too, so switching a server to exo (or adding one)
            // at runtime begins populating its loaded-model snapshot without an app relaunch.
            monitor.start(servers: activeServers, registry: registry)
            // Reachability was previously started only at launch (ModeloApp), so a server
            // added, removed, or (un)paused at runtime kept the stale launch-time probe
            // set until relaunch — paused servers kept getting probed forever.
            reachability.start(servers: activeServers)
            await refreshModels()
        }
        .background(WindowAccessor { hostWindow = $0 }.frame(width: 0, height: 0))
        .onAppear { restoreRoute(); consumePendingSettings(); consumeTappedConversation(); notifier.requestAuthorization(); updateForeground(); constrainWindowToScreen() }
        .onChange(of: inspectorOpen) { constrainWindowToScreen() }
        // Navigating can swap in a taller detail view, which SwiftUI satisfies by
        // growing the window; re-clamp so it can't run off the screen. The
        // hostWindow trigger covers the first clamp, which fires before the
        // window has been resolved from the view hierarchy.
        .onChange(of: route) { constrainWindowToScreen() }
        .onChange(of: hostWindow) { constrainWindowToScreen() }
        // Two-parameter `onChange` is load-bearing: a single-parameter closure binds
        // to the deprecated `onChange(of:perform:)`, whose argument is the *new*
        // value. The empty-chat reclaim below then deleted the chat just navigated
        // to rather than the one navigated away from.
        .onChange(of: route) { oldRoute, newRoute in
            saveRoute(newRoute); syncPickedModel(); updateForeground()
            // Close a console left open on a chat so it doesn't get stuck open
            // (with no toolbar button to dismiss it) on Settings / Reports / Status.
            if !routeSupportsConsole { inspectorOpen = false }
            // Delete a chat that was never used: if the user navigated away from
            // a conversation that has no messages, reclaim it so the sidebar
            // doesn't accumulate empty "New Chat" stubs. A chat that received a
            // send (even a failed one) has ≥1 messages and survives.
            if case .conversation(let id) = oldRoute,
               let convo = conversations.first(where: { $0.persistentModelID == id }),
               convo.messages.isEmpty {
                sessionStore.discard(convo.persistentModelID)
                context.delete(convo)
                context.saveOrLog()
            }
        }
        // A tapped reply notification routes here. Handled in onAppear too, so a tap
        // that re-opens a closed window (menu-bar mode) still lands on the chat.
        .onChange(of: notifier.tappedConversation) { consumeTappedConversation() }
        // ⌘, / "Manage models" while the window is already open. Handled in onAppear
        // too, so a ⌘, that re-opens a closed window (menu-bar mode) lands on settings.
        .onChange(of: settingsNavigator.requestID) { consumePendingSettings() }
        .focusedSceneValue(\.modeloCommands, ModeloCommands(
            newChat: { newChat() },
            goToLauncher: { route = .launcher },
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
        case .personas:
            PersonasManagerView()
        case .status:
            ServerStatsView(endpointFilter: $endpointFilter,
                            onChat: { item in Task { await launch(model: item) } })
        case .reports:
            ReportingView()
        case .settings:
            SettingsView()
        case .project(let id):
            if let project = projectStore.projects.first(where: { $0.id == id }) {
                ProjectLandingView(project: project) { proj in newChatInProject(proj) }
            } else {
                launcher
            }
        case .conversation:
            if let convo = selectedConversation {
                ChatView(conversation: convo, discovered: discoveredWithLiveState, pickedModel: $pickedModel, onModelSelect: handleModelSelection, onModelEject: handleModelEject, onNewChat: newChat)
                    .id(convo.persistentModelID)
            } else {
                launcher
            }
        }
    }

    private var launcher: some View {
        ModelCatalogView(
            discovered: discoveredWithLiveState,
            onLaunch: { model in Task { await launch(model: model) } },
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
        context.saveOrLog()
        route = .conversation(convo.persistentModelID)
    }

    /// Presents the RAM-cost confirmation and suspends until the user chooses.
    private func confirmExoLoad(_ model: DiscoveredModel) async -> Bool {
        // A prompt is already on screen — decline rather than clobber the live
        // continuation (which would leak it and hang the first caller).
        guard pendingExoLoad == nil else { return false }
        return await withCheckedContinuation { continuation in
            pendingExoLoad = ExoLoadPrompt(model: model, continuation: continuation)
        }
    }

    /// Launcher tile tap — creates a chat pre-bound to a model. The persona is
    /// chosen later from the chat composer's picker.
    private func launch(model: DiscoveredModel) async {
        // Load the model first if it's an LM Studio model and not loaded
        if model.server.kind == .lmStudio, !model.model.isLoaded {
            let endpoint = Endpoint(server: model.server, keychain: keychain)
            do {
                _ = try await client.loadModel(modelID: model.model.id, endpoint: endpoint)
                await refreshModels()
            } catch {
                // If loading fails, still proceed - the error will surface in chat
                Log.network.error("Model load before launch failed for \(model.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else if model.server.kind == .exo, !model.model.isLoaded {
            guard await confirmExoLoad(model) else { return }
            let endpoint = Endpoint(server: model.server, keychain: keychain)
            do {
                try await exoClient.placeInstance(modelID: model.model.id, endpoint: endpoint)
                await refreshModels()
            } catch {
                Log.network.error("exo place failed for \(model.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        pickedModel = model
        let convo = Conversation(modelID: model.model.id, serverID: model.server.id)
        context.insert(convo)
        context.saveOrLog()
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

    /// Navigates to the chat from a tapped notification, if one is pending, then
    /// clears the signal so the same tap can't re-fire. The notifier is App-owned,
    /// so a pending tap survives until a window is present to consume it — which is
    /// what makes a tap work when the app was running menu-bar-only.
    private func consumeTappedConversation() {
        guard let id = notifier.tappedConversation else { return }
        route = .conversation(id)
        notifier.tappedConversation = nil
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

    /// Clamps the window's vertical position so its bottom edge never falls below
    /// the screen's visible frame. Called after appear and inspector toggles because
    /// the inspector panel can grow the window downward off-screen.
    private func constrainWindowToScreen() {
        DispatchQueue.main.async {
            // Must be *this* window, not whichever is key: with an expanded-table
            // window open and focused, the old key-window lookup clamped that one.
            guard let window = hostWindow,
                  let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            else { return }
            var frame = window.frame
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            guard frame != window.frame else { return }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func saveRoute(_ route: SidebarRoute?) {
        switch route {
        case .launcher:              storedRoute = "launcher"
        case .personas:              storedRoute = "personas"
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

    private func consumePendingSettings() {
        if settingsNavigator.consumeRequest() { route = .settings }
    }

    private func restoreRoute() {
        guard route == nil else { return }
        if storedRoute.isEmpty {
            route = .launcher
            return
        }
        switch storedRoute {
        case "launcher":  route = .launcher
        case "personas":  route = .personas
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
        } catch {
            Log.chat.error("Title generation stream failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let title = ChatSession.cleanTitle(raw)
        guard !title.isEmpty, convo.modelContext != nil else { return }
        convo.title = title
        context.saveOrLog()
    }

    /// Re-discover when a server is added/edited/removed (or comes online), not just
    /// when the online set changes — so a newly-configured server's models appear.
    private var serverDiscoveryKey: String {
        servers.map { "\($0.id)|\($0.host)|\($0.port)|\($0.kindRaw)|\(registry.isOnline($0))|\($0.metricsAgentURL ?? "")|\($0.localGPU)|\($0.isPaused)" }
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
        context.saveOrLog()
        route = .conversation(convo.persistentModelID)
    }

    /// `discovered` overlaid with live loaded/keepInRam state from the 3-second monitor poll.
    /// Since `monitor` is @Observable, SwiftUI re-renders the launcher automatically each poll cycle.
    /// Filters paused servers here (not just in refreshModels) so the UI responds immediately when
    /// isPaused is toggled, without waiting for the async refresh to complete.
    private var discoveredWithLiveState: [DiscoveredModel] {
        discovered.filter { !$0.server.isPaused }.map { item in
            guard item.server.kind == .lmStudio || item.server.kind == .exo else { return item }
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

    private func refreshModels() async {
        // Query every non-paused server, not just ones the reachability monitor has already
        // flagged online — a freshly-added/edited server (or one that came up after
        // launch) is "unknown" until its next probe, and we shouldn't hide its models
        // in the meantime. fetchModels fails fast for genuinely-offline servers.
        let targets = servers
            .filter { !$0.isPaused }
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

        // A server that just returned a model list is, by definition, reachable —
        // mark it online so its dot turns green without waiting for the next probe.
        // Exception: cloud servers with no key are reachable via public endpoints
        // but can't be used for chat — keep them in .needsKey rather than .online.
        for (index, target) in targets.enumerated() where !(modelsByIndex[index] ?? []).isEmpty {
            if !target.server.kind.isLocal, target.endpoint.apiKey == nil { continue }
            registry.setStatus(.online, for: target.server)
        }

        discovered = targets.enumerated().flatMap { index, target in
            (modelsByIndex[index] ?? []).map { DiscoveredModel(server: target.server, model: $0) }
        }
    }

    /// Unloads a model on LM Studio and clears the selection if it was the active model.
    private func handleModelEject(_ item: DiscoveredModel) async {
        let endpoint = Endpoint(server: item.server, keychain: keychain)
        if item.server.kind == .exo {
            let loaded = (try? await exoClient.loadedInstances(endpoint: endpoint)) ?? []
            guard let instance = loaded.first(where: { $0.modelID == item.model.id }) else { return }
            do {
                try await exoClient.deleteInstance(instanceID: instance.instanceID, endpoint: endpoint)
                await refreshModels()
                if pickedModel?.model.id == item.model.id { pickedModel = nil }
            } catch {
                Log.network.error("exo unload failed for \(item.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        do {
            _ = try await client.unloadModel(modelID: item.model.id, endpoint: endpoint)
            await refreshModels()
            if pickedModel?.model.id == item.model.id {
                pickedModel = nil
            }
        } catch {
            // State will reconcile on next refresh.
            Log.network.error("Model eject failed for \(item.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pins a model on LM Studio so it won't be auto-evicted when another model loads.
    private func handleModelPin(server: Server, modelID: String) async {
        let endpoint = Endpoint(server: server, keychain: keychain)
        do {
            try await client.setKeepInRam(modelID: modelID, keepInRam: true, endpoint: endpoint)
            await refreshModels()
        } catch {
            // State will reconcile on next refresh.
            Log.network.error("Model pin failed for \(modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unpins a model on LM Studio so it may be evicted when another model loads.
    private func handleModelUnpin(server: Server, modelID: String) async {
        let endpoint = Endpoint(server: server, keychain: keychain)
        do {
            try await client.setKeepInRam(modelID: modelID, keepInRam: false, endpoint: endpoint)
            await refreshModels()
        } catch {
            // State will reconcile on next refresh.
            Log.network.error("Model unpin failed for \(modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            Log.network.error("Model load on selection failed for \(item.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

/// App menu ▸ Settings… (⌘,) — routes the main window to the in-app settings
/// pane. There is no separate Settings window: with the main window closed
/// (menu-bar-only mode) this reopens it, landing directly on settings.
///
/// Unlike the Go commands this doesn't use `@FocusedValue` — that would be nil
/// with no focused window, exactly the case ⌘, must still work in. The navigator
/// is handed in by `ModeloApp`, which owns it.
struct SettingsCommand: View {
    let navigator: SettingsNavigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            navigator.open()
            // Reuse the existing main window if one is around (even miniaturized);
            // only create one when none exists. Modelo is deliberately
            // single-window — File ▸ New Window is replaced by New Chat — so
            // openWindow(id:) on the WindowGroup must stay the last resort: it
            // would add a second instance if a window already existed.
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix(ModeloApp.mainWindowID) == true
            }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: ModeloApp.mainWindowID)
            }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

