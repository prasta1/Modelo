import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

/// Center detail: a model spec-plate header, the scrolling message stream, the
/// context gauge, and a composer deck. Streaming is driven by a `ChatSession`
/// owned here.
struct ChatView: View {
    @Bindable var conversation: Conversation
    let discovered: [DiscoveredModel]
    @Binding var pickedModel: DiscoveredModel?
    /// Callback fired when the user picks a model. Implement to load/unload models.
    let onModelSelect: ((DiscoveredModel) async -> Bool)?
    /// Callback fired when the user ejects a loaded model.
    let onModelEject: ((DiscoveredModel) async -> Void)?
    /// Callback fired when the user double-clicks a model row to start a new chat.
    let onNewChat: (() -> Void)?
    /// Age of the picker's prices and how to refetch them (see `ModelPricing`).
    var pricesRefreshedAt: Date? = nil
    var onRefreshModels: (() async -> Void)? = nil
    @Environment(ServerRegistry.self) private var registry
    @Environment(MCPServerManager.self) private var mcpManager
    @Environment(ChatSessionStore.self) private var sessionStore
    @Environment(ChatNotifier.self) private var notifier
    @Environment(\.modelContext) private var context
    @Environment(SettingsNavigator.self) private var settingsNavigator

    @State private var draft = ""
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var isDragTarget = false
    /// True while `ensureLoaded()` waits on an LM Studio load before a turn.
    @State private var isLoadingModel = false
    /// Set when the user taps "edit & resend" on a past user turn; the next send
    /// forks a sibling branch under that message instead of extending the path.
    @State private var editingSource: Message?
    @State private var composerFocused: Bool = false
    @State private var composerHeight: CGFloat = 22
    @State private var commandFeedback: String?
    /// Messages typed while a reply is streaming; auto-sent in order on completion (§3.3).
    @State private var pendingQueue: [String] = []
    /// Keyboard-highlighted row in the slash-command popup (§3.1).
    @State private var slashSelection = 0
    /// Skills switched on in Settings ▸ Skills; refreshed when the user starts a `/`
    /// command so newly installed or toggled skills show up (§3.7).
    @State private var enabledSkills: [AgentSkill] = []
    /// The artifact currently open in the side panel (§2.4), by id.
    @State private var openArtifactID: String?
    /// Last-open artifact, so the header toggle can reopen what you were viewing.
    @State private var lastArtifactID: String?
    /// Draggable artifact-panel width (persisted); `dragStartWidth` anchors a live drag.
    @AppStorage("artifactPanelWidth") private var artifactPanelWidth: Double = 460
    @State private var dragStartWidth: Double?
    /// Console inspector state (shared with ContentView). Auto-collapsed while an
    /// artifact is open so the two right-side panels don't crowd each other out.
    @AppStorage("consoleInspectorOpen") private var consoleOpen = false
    @State private var consoleWasOpen = false
    /// Live width of the chat detail area, so the artifact panel can't shrink the chat
    /// below `ArtifactPanelSizing.minChatWidth`. Seeded wide to avoid a first-layout squeeze.
    @State private var detailWidth: CGFloat = 1200
    // Whether to teach the model the artifact syntax (opt-out in Settings ▸ Tools).
    @AppStorage("artifactsEnabled") private var artifactsEnabled = true
    // Adjustable chat text size, shared with MessageRow and the View menu (⌘+ / ⌘-).
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    // Global sampling defaults (JSON-encoded SamplingParams), edited in Settings ▸ Sampling.
    @AppStorage("globalSamplingJSON") private var globalSamplingJSON = "{}"
    // Max agentic tool rounds per turn — configurable in Settings ▸ Tools, applied to
    // the session at creation and kept in sync while the chat is open.
    @AppStorage("globalMaxToolRounds") private var maxToolRounds = ChatSession.defaultMaxToolRounds
    // Global YOLO mode (Settings ▸ Tools) — ORed with the per-chat switch below.
    @AppStorage("yoloModeEnabled") private var globalYolo = false
    // First-party filesystem/shell tools — opt-in, off by default (Settings ▸ Tools).
    @AppStorage(FSToolSettings.enabledKey) private var fsToolsEnabled = false
    @AppStorage(FSToolSettings.shellKey)   private var shellToolEnabled = false
    @AppStorage(FSToolSettings.rootKey)    private var fsToolsRoot = ""
    @AppStorage(MemoryStore.enabledKey)    private var memoryEnabled = false
    // Settings ▸ General: show the persona picker above the composer.
    @AppStorage("showPersonaBar") private var showPersonaBar = true
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    @State private var showSampling = false
    /// Turning YOLO on from the header chip asks first: it's one click from letting the
    /// model run shell commands unprompted.
    @State private var confirmYolo = false
    @State private var showBenchmark = false
    /// Reference to the AppKit view behind the chat column, resolved at click time
    /// by the screenshot button to capture exactly what's on screen.
    @State private var snapshotProbe = SnapshotProbeView.Holder()
    @State private var pendingSnapshot: SnapshotItem?
    @State private var errorCopied = false
    /// When `/clear` was first run; a second run within a few seconds confirms it.
    @State private var clearArmedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Identity key for this conversation's session/task in the shared store.
    private var convoID: PersistentIdentifier { conversation.persistentModelID }
    /// The streaming session for this conversation, owned by the store so a turn
    /// survives this view being torn down when the user switches chats (concurrency).
    private var session: ChatSession? { sessionStore.session(for: convoID) }

    /// The server to send to. Prefer the header's picked model — it's the user's live
    /// selection — so a send always goes where the header says, not a stale persisted
    /// `serverID`. Falls back to `serverID` only before a model is picked.
    private var boundServer: Server? {
        pickedModel?.server
            ?? discovered.first { $0.server.id == conversation.serverID }?.server
    }

    /// Sync the conversation's model/server to the header selection so the resolved
    /// server and `conversation.modelID` always agree before a request goes out.
    private func bindPickedModel() {
        if let picked = pickedModel {
            conversation.modelID = picked.model.id
            conversation.serverID = picked.server.id
        }
    }

    /// The picker binding. `pickedModel` is app-global, so we can't write the
    /// conversation on every change (navigating between chats mutates it). Instead
    /// the *setter* — only ever called by an explicit pick in this chat's picker —
    /// records the model/server on the conversation immediately, so a new chat routes
    /// correctly without waiting for the first send to `bindPickedModel`.
    private var pickedModelBinding: Binding<DiscoveredModel?> {
        Binding(
            get: { pickedModel },
            set: { newValue in
                pickedModel = newValue
                if let picked = newValue {
                    conversation.modelID = picked.model.id
                    conversation.serverID = picked.server.id
                    context.saveOrLog()
                }
            }
        )
    }

    /// User override first, then the live entry's loaded context. `pickedModel` is a
    /// copy taken at pick time — before an LM Studio load — so it only knows the
    /// declared maximum; `discovered` carries the monitor's live state.
    private var contextWindow: Int {
        let live = discovered.first { $0.id == pickedModel?.id }?.model ?? pickedModel?.model
        return boundServer?.contextLength(for: pickedModel?.model.id ?? "") ?? live?.contextWindow ?? 0
    }

    /// Display name of the per-chat workspace folder, or nil when none is set.
    /// Computed once and shared by the system-suffix builder and the workspace chip.
    private var workspaceFolderName: String? {
        guard let path = conversation.projectPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }


    /// System suffix injected into every request: artifact rendering instructions
    /// and, when a local workspace is active, a note so the model knows it can
    /// read/write files on this Mac using the file tools.
    private var combinedSystemSuffix: String? {
        var parts: [String] = []
        if artifactsEnabled { parts.append(ArtifactInstructions.system) }
        if let path = conversation.projectPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path),
           let name = workspaceFolderName {
            parts.append("""
            You have read/write access to the user's local filesystem on this Mac. \
            Workspace root: \(path) (folder: "\(name)"). \
            Use read_file to read files, glob to list them, grep to search contents, \
            write_file to create or overwrite, and edit_file to make targeted edits. \
            When the user references a file or directory, look for it here first.
            """)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The currently-selected branch, root→leaf (§1.2). Siblings on other branches
    /// are hidden; navigating siblings re-selects the active leaf.
    private var pathMessages: [Message] {
        conversation.activePath()
    }

    /// Effective sampling for this turn (§1.4): the conversation's overrides layered
    /// over the global defaults from Settings.
    private var effectiveSampling: SamplingParams {
        let global = (try? JSONDecoder().decode(SamplingParams.self,
                                                from: Data(globalSamplingJSON.utf8))) ?? SamplingParams()
        return conversation.samplingOverride.overlaying(global)
    }

    /// YOLO for this chat: the global setting or the per-conversation switch.
    /// When on, mutating tools run unprompted and the round cap is lifted.
    private var effectiveYolo: Bool {
        globalYolo || conversation.yoloEnabled
    }

    /// Tool-round cap for this chat: the per-conversation override, else the
    /// global Settings value (same resolution idiom as `effectiveSampling`).
    private var effectiveMaxRounds: Int {
        conversation.maxToolRoundsOverride ?? maxToolRounds
    }

    /// Artifacts across the active path, grouped into versions (§2.4).
    private var artifactGroups: [ArtifactGroup] { ArtifactCollector.groups(from: pathMessages) }
    private var openArtifactGroup: ArtifactGroup? {
        openArtifactID.flatMap { id in artifactGroups.first { $0.id == id } }
    }

    /// Artifact panel width as shown (see `ArtifactPanelSizing`).
    private var clampedArtifactWidth: Double {
        ArtifactPanelSizing.clamp(artifactPanelWidth, detailWidth: Double(detailWidth))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                messageStream
                footer
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            // Invisible; spans the chat column so the screenshot button knows
            // exactly which region of the window to capture.
            .background(SnapshotProbeView(holder: snapshotProbe))

            if let group = openArtifactGroup {
                artifactResizeHandle
                ArtifactPanel(groups: artifactGroups,
                              selectedID: group.id,
                              onSelect: { openArtifactID = $0 },
                              onClose: { openArtifactID = nil })
                    .frame(width: clampedArtifactWidth)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Measure width with a non-layout background reader. Wrapping the whole body in a
        // GeometryReader (as before) made it the layout container and collapsed the message
        // stream's own GeometryReader whenever the footer changed height — e.g. dismissing
        // the tool-approval card blanked the transcript until the next reply forced a relayout.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { detailWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, w in detailWidth = w }
            }
        )
        // Animate the panel sliding in/out, but not switches between artifacts.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: openArtifactID == nil)
        .background(Theme.windowBG)
        // Accelerators for actions that otherwise need the mouse. Zero-size buttons
        // still receive their shortcuts; Esc only stops while a reply is streaming.
        .background {
            Group {
                Button("Focus composer") { composerFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Stop generating") { stop() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!isStreaming)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { ensureSession() }
        // No .onDisappear cancel: a turn keeps streaming after the user leaves the
        // chat, so multiple conversations can run at once (the store owns it).
        // Keep an open chat's tool-call cap and YOLO mode in sync with the Settings
        // values and the per-chat overrides (agent popover).
        .onChange(of: effectiveMaxRounds) { session?.maxToolRounds = effectiveMaxRounds }
        .onChange(of: effectiveYolo) { session?.yoloMode = effectiveYolo }
        // Streaming and errors are otherwise visual-only; announce them to VoiceOver.
        .onChange(of: isStreaming) { was, now in
            if was && !now { AccessibilityNotification.Announcement("Reply finished").post() }
        }
        .onChange(of: session?.errorText) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: openArtifactID) { old, new in
            if let new { lastArtifactID = new }
            withAnimation(.easeOut(duration: 0.2)) {
                if old == nil, new != nil {
                    // Opening: tuck the console away so both panels aren't crammed.
                    if consoleOpen { consoleWasOpen = true; consoleOpen = false }
                } else if old != nil, new == nil {
                    // Closing: restore the console if we collapsed it.
                    if consoleWasOpen { consoleOpen = true }
                    consoleWasOpen = false
                }
            }
        }
        // Auto-open the newest artifact when the model produces a new one (Claude-style).
        // Only on increase: branch switches can lower the count and must not force the panel open.
        .onChange(of: artifactGroups.count) { old, new in
            if new > old, let newest = artifactGroups.last { openArtifactID = newest.id }
        }
        .sheet(item: $pendingSnapshot) { item in
            SnapshotPreviewView(url: item.url)
        }
    }

    // MARK: Header — model spec plate + live status

    private var header: some View {
        VStack(spacing: 8) {
            // Every action gets its own button when the row has room; on a narrow chat
            // column (artifact panel open, workspace chip showing) Benchmark and Screenshot
            // fold back into the ⋯ menu instead of squeezing the row.
            ViewThatFits(in: .horizontal) {
                headerRow(compact: false)
                headerRow(compact: true)
            }
            // On the stable container, not a row ViewThatFits may swap out.
            .sheet(isPresented: $showBenchmark) {
                BenchmarkView(discovered: discovered, initial: pickedModel)
            }
            if let model = pickedModel?.model {
                HStack {
                    SpecStrip(model: model)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.windowBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func statusPill(for server: Server) -> some View {
        let status = registry.status(for: server)
        let live = status == .online
        return HStack(spacing: 6) {
            StatusLED(status: status, size: 6)
            Text(status.displayLabel)
                .font(.mono(9)).tracking(1)
                .foregroundStyle(live ? Theme.green : Theme.textMute)
            Text(server.label)
                .font(.mono(10))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
        // The LED is colour-only; the label text carries the state for VoiceOver.
        .accessibilityElement(children: .combine)
    }

    /// Draggable separator that resizes the artifact panel (§2.4). The 1pt line sits
    /// inside a wider invisible hit area with a resize cursor.
    private var artifactResizeHandle: some View {
        // A real-width column (its own layout space) so the whole zone is grabbable,
        // not just the 1pt line — overlapping the neighbors lost the hit-test before.
        ZStack {
            Color.clear
            Rectangle().fill(Theme.line).frame(width: 1)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let base = dragStartWidth ?? artifactPanelWidth
                    dragStartWidth = base
                    artifactPanelWidth = ArtifactPanelSizing.dragged(
                        storedWidth: base, translation: value.translation.width,
                        detailWidth: Double(detailWidth))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }

    /// Toggles the artifact side panel. Only shown once the chat has artifacts (§2.4).
    @ViewBuilder private var artifactsButton: some View {
        if !artifactGroups.isEmpty {
            let open = openArtifactID != nil
            Button {
                if open {
                    openArtifactID = nil
                } else {
                    let remembered = lastArtifactID.flatMap { id in
                        artifactGroups.contains { $0.id == id } ? id : nil
                    }
                    openArtifactID = remembered ?? artifactGroups.last?.id
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(open ? Theme.amber : Theme.Palette.inkDim)
                    .frame(width: 30, height: 26)
                    .panel(Theme.Palette.panel, radius: 7)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("\\", modifiers: .command)
            .help(open ? "Hide artifacts (\(artifactGroups.count)) — ⌘\\" : "Show artifacts (\(artifactGroups.count)) — ⌘\\")
            .accessibilityLabel("Artifacts panel")
        }
    }

    /// Header chip for this chat's YOLO mode — red while tools run without asking.
    /// Locked on when YOLO is enabled for every chat in Settings ▸ Tools.
    private var yoloChip: some View {
        Toggle("YOLO", isOn: Binding(
            get: { effectiveYolo },
            set: { on in
                if on {
                    confirmYolo = true
                } else {
                    conversation.yoloEnabled = false
                    context.saveOrLog()
                }
            }))
            .toggleStyle(ChipToggleStyle(tint: Theme.Palette.alert))
            .disabled(globalYolo)
            .help(globalYolo ? "YOLO is on for every chat (Settings ▸ Tools)"
                  : effectiveYolo ? "Tools run without asking in this chat — click to turn off"
                  : "Run writes, edits and shell commands without asking in this chat")
            .confirmationDialog("Run tools without asking?", isPresented: $confirmYolo) {
                Button("Turn On YOLO", role: .destructive) {
                    conversation.yoloEnabled = true
                    context.saveOrLog()
                }
            } message: {
                Text("In this chat, writes, edits and shell commands will run without an approval card, and the tool-call limit is lifted.")
            }
    }

    /// True when this chat deviates from the global defaults in anything the
    /// settings popover controls (sampling, agent limits). YOLO has its own chip.
    private var hasOverrides: Bool {
        conversation.samplingOverride != SamplingParams()
            || conversation.maxToolRoundsOverride != nil
    }

    /// One entry point for per-chat sampling, agent behavior and workspace. Shows an
    /// amber dot when any override is active.
    private var settingsButton: some View {
        let tint: Color = hasOverrides ? Theme.amber
            : Theme.Palette.inkDim
        return Button { showSampling.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
                .overlay(alignment: .topTrailing) {
                    if hasOverrides {
                        Circle().fill(tint).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(hasOverrides ? "Chat settings — this chat overrides the defaults" : "Chat settings")
        .accessibilityLabel("Chat settings")
        .accessibilityValue(hasOverrides ? "Overrides active" : "Defaults")
        .popover(isPresented: $showSampling, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                samplingSection
                if pickedModel?.model.supportsToolUse == true {
                    Divider().overlay(Theme.line)
                    agentSection
                }
                if conversation.projectPath?.isEmpty ?? true {
                    Divider().overlay(Theme.line)
                    workspaceSection
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    /// Offered only while no workspace is set; once set, the header chip shows it.
    private var workspaceSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                Text("A local folder the model can read and write on this Mac.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Choose…") { showSampling = false; pickWorkspace() }
                .font(Theme.metric(11))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.amber)
        }
    }

    /// The header's control row. `compact` folds Benchmark and Screenshot into ⋯.
    @ViewBuilder private func headerRow(compact: Bool) -> some View {
        HStack(spacing: 12) {
            ModelPickerView(discovered: discovered, selection: pickedModelBinding, onModelSelect: onModelSelect, onModelEject: onModelEject, onNewChat: onNewChat,
                            pricesRefreshedAt: pricesRefreshedAt, onRefresh: onRefreshModels)
            if pickedModel?.model.supportsToolUse == true {
                Toggle("Tools", isOn: $conversation.toolsEnabled)
                    .toggleStyle(ChipToggleStyle())
                    .help("Allow this model to call tools")
            }
            // Also shown whenever YOLO is on, so it can always be switched off.
            if pickedModel?.model.supportsToolUse == true || effectiveYolo {
                yoloChip
            }
            workspaceButton
            artifactsButton
            settingsButton
            if compact {
                moreMenu
            } else {
                headerIconButton("Benchmark a model", systemImage: "gauge.with.dots.needle.67percent") {
                    showBenchmark = true
                }
                .disabled(discovered.isEmpty)
                headerIconButton("Screenshot this chat", systemImage: "camera.viewfinder", action: takeScreenshot)
            }
            Spacer(minLength: 8)
            if let server = pickedModel?.server {
                statusPill(for: server)
            }
        }
    }

    /// A square header button in the same chrome as the artifacts/settings buttons; the
    /// title is hidden visually but kept for VoiceOver and the tooltip.
    private func headerIconButton(_ title: String, systemImage: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// Narrow-header fallback: the load-test sheet (§2.5) and a share-ready PNG card of
    /// what's on screen (saved to ~/Downloads and copied) when they don't fit as buttons.
    private var moreMenu: some View {
        Menu {
            Button("Benchmark a model…") { showBenchmark = true }
                .disabled(discovered.isEmpty)
            Button("Screenshot this chat…") { takeScreenshot() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
    /// Sampling controls for the settings popover (§1.4b).
    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Sampling · this chat")
                Spacer()
                if !presets.isEmpty {
                    Menu("Apply preset") {
                        ForEach(presets) { preset in
                            Button(preset.name) { apply(preset) }
                        }
                    }
                    .font(Theme.metric(11))
                    .fixedSize()
                    .help("Apply a saved preset to this chat")
                }
                Button("Reset") { conversation.samplingOverride = SamplingParams(); context.saveOrLog() }
                    .font(Theme.metric(11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
                    .help("Reset to global defaults")
                    .accessibilityLabel("Reset sampling to defaults")
            }
            SamplingControls(params: Binding(get: { conversation.samplingOverride },
                                             set: { conversation.samplingOverride = $0 }))
            Text("Overrides the global defaults from Settings for this chat only.")
                .font(Theme.metric(10)).foregroundStyle(Theme.textDim)

            Divider().overlay(Theme.line)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-compact long chats").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                    Text("Summarize older turns near the context limit (§1.5).")
                        .font(Theme.metric(10)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                PillToggle(isOn: $conversation.autoCompact)
            }
        }
        .onChange(of: conversation.samplingOverride) { context.saveOrLog() }
        .onChange(of: conversation.autoCompact) { context.saveOrLog() }
    }

    /// Per-chat agent behavior: the tool-call limit override. (YOLO is the header chip.)
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Agent · this chat")
                Spacer()
                Button("Reset") {
                    conversation.maxToolRoundsOverride = nil
                    context.saveOrLog()
                }
                .font(Theme.metric(11))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Use the global tool-call limit")
                .accessibilityLabel("Reset the tool-call limit")
            }
            Stepper(value: Binding(get: { conversation.maxToolRoundsOverride ?? maxToolRounds },
                                   set: { conversation.maxToolRoundsOverride = $0 == maxToolRounds ? nil : $0 }),
                    in: 1...20) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max tool calls per turn").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                        Text("Overrides the Settings default for this chat only.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 8)
                    if effectiveYolo {
                        Text("Unlimited").font(Theme.metric(11)).foregroundStyle(Theme.Palette.alert)
                    } else {
                        Text("\(effectiveMaxRounds)")
                            .font(.mono(13)).monospacedDigit()
                            .foregroundStyle(conversation.maxToolRoundsOverride != nil ? Theme.amber : Theme.textMid)
                    }
                }
            }
            .disabled(effectiveYolo)
            if conversation.maxToolRoundsOverride != nil {
                Button("Use default (\(maxToolRounds))") {
                    conversation.maxToolRoundsOverride = nil
                    context.saveOrLog()
                }
                .font(Theme.metric(11))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }
        }
        .onChange(of: conversation.yoloEnabled) { context.saveOrLog() }
        .onChange(of: conversation.maxToolRoundsOverride) { context.saveOrLog() }
    }


    /// Snapshot → card → temp file → preview sheet with Share / Done.
    private func takeScreenshot() {
        let stamp = Date()
        guard let probe = snapshotProbe.view,
              let scale = probe.window?.backingScaleFactor,
              let shot = SessionSnapshot.capture(around: probe),
              let card = SessionSnapshot.card(
                  from: shot,
                  caption: SessionSnapshot.caption(title: conversation.displayTitle,
                                                   modelID: pickedModel?.model.id,
                                                   stamp: stamp),
                  scale: scale),
              let url = SessionSnapshot.writeToTemp(card, title: conversation.displayTitle,
                                                    stamp: stamp)
        else {
            flash("Screenshot failed — couldn't capture the chat window.")
            return
        }
        pendingSnapshot = SnapshotItem(url: url)
    }

    /// Shows the active workspace as an amber chip (tap to change, ✕ to clear);
    /// renders nothing when no workspace is set (pick one in Chat settings).
    /// Lets the model on the remote server read/write files on this Mac.
    @ViewBuilder private var workspaceButton: some View {
        if let path = conversation.projectPath, !path.isEmpty {
            let name = workspaceFolderName ?? path
            HStack(spacing: 0) {
                Button(action: pickWorkspace) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.amber)
                        Text(name)
                            .font(.mono(10))
                            .foregroundStyle(Theme.amber)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 120, alignment: .leading)
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("Local workspace — click to change folder")

                Button(action: clearWorkspace) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isStreaming ? Theme.textFaint : Theme.textDim)
                        .padding(.trailing, 9)
                        .padding(.leading, 3)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .disabled(isStreaming)
                .help(isStreaming ? "Stop the current reply before changing workspace"
                                  : "Clear workspace — model loses local file access")
            }
            .background(Theme.amberFillLo, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.amberBorder))
        }
    }

    /// Applies a preset's system prompt (if any) and sampling overrides to this chat.
    private func apply(_ preset: Preset) {
        conversation.apply(preset)
        context.saveOrLog()
    }

    // MARK: Message stream

    private var messageStream: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if conversation.messages.isEmpty {
                        emptyConversationHint
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    } else {
                        let path = pathMessages
                        TranscriptStack {
                            ForEach(path) { msg in
                                MessageRow(
                                    message: msg,
                                    modelName: conversation.modelID,
                                    onReuse: reuseDraft,
                                    onSelectBranch: selectBranch,
                                    onRegenerate: regenerate,
                                    // Only the last assistant turn streams; gate Markdown
                                    // rendering off until it finishes.
                                    isLiveStreaming: session?.isStreaming == true
                                        && msg.role == .assistant
                                        && msg.id == path.last?.id,
                                    onOpenArtifact: { openArtifactID = $0 },
                                    openArtifactID: openArtifactID
                                )
                                // Skip unchanged rows on the ~20fps streaming re-render.
                                .equatable()
                                .id(msg.id)
                            }
                            Color.clear.frame(height: 1).id(bottomAnchor)
                                // macOS 14 only: visibility of this sentinel = "user is at
                                // the bottom". It's coarse (the lazy stack keeps it loaded
                                // well past the viewport), so macOS 15+ measures the real
                                // scroll position instead (`followsScrollPosition`).
                                // Defer state mutation past the current layout pass —
                                // onAppear/onDisappear inside LazyVStack can fire during
                                // layout, and a synchronous write here can open a new CA
                                // transaction mid-commit.
                                .onAppear {
                                    if #unavailable(macOS 15) { Task { @MainActor in isNearBottom = true } }
                                }
                                .onDisappear {
                                    if #unavailable(macOS 15) { Task { @MainActor in isNearBottom = false } }
                                }
                        }
                        .padding(20)
                        // Bottom-align short conversations so the latest turn sits just
                        // above the composer rather than stranding it under a void.
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
                    }
                }
                .scrollIndicators(.hidden)
                .hideScrollIndicators()
                .modifier(FollowsScrollPosition(isNearBottom: $isNearBottom, userScrolling: $userScrolling))
                // Shown while the user reads history; returns to the latest turn and
                // resumes following.
                .overlay(alignment: .bottomTrailing) {
                    if !isNearBottom && !conversation.messages.isEmpty {
                        Button {
                            isNearBottom = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scrollToBottom(proxy) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.amber)
                                .frame(width: 30, height: 30)
                                .background(Theme.popoverBG, in: Circle())
                                .overlay(Circle().stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                        .help("Jump to latest")
                        .accessibilityLabel("Jump to latest message")
                        .transition(.opacity)
                    }
                }
                // Scroll to bottom when a new message is appended, but only if
                // the user hasn't scrolled away to read history.
                .onChange(of: conversation.messages.count) {
                    if isNearBottom && !userScrolling { scrollToBottom(proxy) }
                }
                // Timer-based scroll during streaming: fires at ~20fps instead of once
                // per token, avoiding layout-pass spam from per-character onChange.
                // Never while the user's own scroll gesture (or its momentum) is running.
                .task(id: session?.isStreaming) {
                    guard session?.isStreaming == true else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        // Don't yank the view back down while the user reads scrollback.
                        if isNearBottom && !userScrolling { scrollToBottom(proxy) }
                    }
                    if isNearBottom && !userScrolling { scrollToBottom(proxy) }
                }
            }
        }
    }

    /// Fills the message area before the first turn so a fresh chat reads as
    /// intentional empty space, not a dead gap above the composer.
    private var emptyConversationHint: some View {
        VStack(spacing: 18) {
            if let picked = pickedModel {
                // What this chat will talk to, at a glance: model, server, live state, window.
                let status = registry.status(for: picked.server)
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        StatusLED(status: status, size: 6)
                        Text(picked.model.familyName)
                            .font(Theme.metric(15))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textHi)
                    }
                    Text("\(picked.server.label) · \(status.displayLabel)"
                         + (contextWindow > 0 ? " · \(contextWindow.formatted()) token context" : ""))
                        .font(.mono(11))
                        .foregroundStyle(Theme.textDim)
                }
                .accessibilityElement(children: .combine)

                // Starters fill the composer; they never send on their own.
                VStack(spacing: 6) {
                    starterRow("terminal", "Type / for commands", "/help, /model, /compact, /export…") {
                        draft = "/"
                    }
                    if picked.model.supportsToolUse {
                        starterRow("wrench.and.screwdriver", "Try the tools",
                                   "Ask what the model can do with them") {
                            draft = "What tools can you use here, and what could you do with them?"
                        }
                    }
                    starterRow("sidebar.right", "Build something to preview",
                               "Code the model writes can open in the artifacts panel") {
                        draft = "Make a small HTML page with a working counter button."
                    }
                }
                .frame(maxWidth: 360)
            } else {
                Image(systemName: "text.bubble")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.textDim)
                Text(discovered.isEmpty
                     ? "No models found. Start a local server or add a cloud API in Settings."
                     : "Pick a model above, then say something.")
                    .font(.mono(12))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    /// One tappable suggestion in the empty state: icon, title, one line of detail.
    private func starterRow(_ icon: String, _ title: String, _ detail: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                    Text(detail).font(Theme.metric(10)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Fills the message box without sending")
    }

    private let bottomAnchor = "BOTTOM"

    /// False while the user has scrolled away from the bottom; gates streaming auto-scroll.
    @State private var isNearBottom = true
    /// True during the user's own scroll gesture and its momentum (macOS 15+); auto-scroll
    /// waits it out so it never fights the user's hand.
    @State private var userScrolling = false

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    // MARK: Footer — error, context gauge, composer

    private var footer: some View {
        VStack(spacing: 0) {
            // The picked server is down: say so before the user types, not after Send.
            if let server = boundServer, !isStreaming,
               let reason = unavailableReason(for: server) {
                HStack(spacing: 8) {
                    StatusLED(status: registry.status(for: server), size: 6)
                    Text(reason)
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.Palette.alert)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.Palette.alert.opacity(0.10))
                .accessibilityElement(children: .combine)
            }

            if let error = session?.errorText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.Palette.alert)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if canRetry {
                        Button("Retry") { retry() }
                            .buttonStyle(.plain)
                            .font(Theme.metric(11))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Palette.alert)
                            .help("Run the failed turn again")
                            .accessibilityHint("Runs the failed turn again")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                        errorCopied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); errorCopied = false }
                    } label: {
                        Image(systemName: errorCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(errorCopied ? Theme.green : Theme.Palette.alert.opacity(0.7))
                            .animation(.easeOut(duration: 0.15), value: errorCopied)
                    }
                    .buttonStyle(.plain)
                    .help("Copy error")
                    .accessibilityLabel("Copy error")
                    Button {
                        session?.errorText = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.alert.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.Palette.alert.opacity(0.10))
            }

            // Standing cue that this chat runs tools unattended (YOLO mode).
            // Guard on supportsToolUse so the banner doesn't show on non-tool models.
            if effectiveYolo && pickedModel?.model.supportsToolUse == true {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert)
                    Text("YOLO mode — tool calls run without approval")
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.Palette.alert)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.Palette.alert.opacity(0.10))
            }

            // Transient slash-command confirmation (§3.1).
            if let commandFeedback {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amber)
                    Text(commandFeedback)
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.textMid)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.amberFillLo)
            }

            // Mutating tool call awaiting the user's go-ahead (file/shell tools). Slides up
            // so a paused reply visibly asks for attention (a fade under Reduce Motion).
            VStack(spacing: 0) {
                if let pending = session?.pendingApproval {
                    ToolApprovalCard(pending: pending,
                                     onDecision: { session?.respondToApproval($0) })
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.15),
                       value: session?.pendingApproval?.preview.id)

            // Slash-command autocomplete (§3.1): appears when the draft starts with "/".
            slashSuggestions

            // Persistent view of messages queued during a stream (§3.3) — stays until
            // each is actually sent, so the queue never looks like it vanished.
            if !pendingQueue.isEmpty {
                queueStrip
            }

            // Hidden when the window is unknown (server only exposed /v1/models), so
            // we don't show a meaningless "0 / 0" bar.
            if contextWindow > 0 {
                ContextBar(used: estimatedContextUsed, window: contextWindow)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            composer
        }
        .background(Theme.windowBG)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    /// Slash-command autocomplete popup (§3.1). Shown above the composer while the
    /// draft is a bare `/word`; clicking a row fills the command (and runs it if it
    /// takes no argument).
    @ViewBuilder private var slashSuggestions: some View {
        let specs = slashSpecs
        let listMode = SlashParser.isSkillsListMode(draft)
        if !specs.isEmpty || listMode {
            VStack(spacing: 0) {
                if listMode { skillsListHeader }
                if listMode && specs.isEmpty {
                    Text(enabledSkills.isEmpty ? "No skills are on." : "No skills match.")
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                // Up to ~8 rows tall; with dozens of skills the list scrolls and the
                // keyboard highlight is kept in view.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                                if spec.isSkill, !listMode, index == 0 || !specs[index - 1].isSkill {
                                    Text("Skills")
                                        .font(Theme.metric(10))
                                        .foregroundStyle(Theme.textFaint)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 6)
                                }
                                SlashSuggestionRow(spec: spec,
                                                   isHighlighted: index == clampedSlashSelection) {
                                    applySuggestion(spec)
                                }
                                .id(spec.id)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: clampedSlashSelection) {
                        if specs.indices.contains(clampedSlashSelection) {
                            proxy.scrollTo(specs[clampedSlashSelection].id)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Theme.popoverBG, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.line))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// Header of the `/skills` list: how many skills are on, and a shortcut to manage them.
    private var skillsListHeader: some View {
        HStack {
            Text("Skills · \(enabledSkills.count) on")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            Button("Settings ▸ Skills…") { settingsNavigator.open(tab: "Skills") }
                .buttonStyle(.plain)
                .font(Theme.metric(10))
                .foregroundStyle(Theme.amber)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Slash suggestions for the current draft, and the clamped keyboard highlight.
    private var slashSpecs: [SlashParser.Spec] { SlashParser.suggestions(for: draft, skills: enabledSkills) }
    private var clampedSlashSelection: Int {
        guard !slashSpecs.isEmpty else { return 0 }
        return min(max(0, slashSelection), slashSpecs.count - 1)
    }

    /// Return key: pick the highlighted slash command if the popup is open, else send.
    private func submitComposer() {
        let specs = slashSpecs
        if !specs.isEmpty {
            applySuggestion(specs[clampedSlashSelection])
        } else if canSend {
            send()
        }
    }

    /// Tab accepts the highlighted suggestion while the popup is open (`/skills` + Tab
    /// opens the skill list); otherwise Tab behaves normally.
    private func acceptSlashSuggestion() -> Bool {
        guard !slashSpecs.isEmpty else { return false }
        applySuggestion(slashSpecs[clampedSlashSelection])
        return true
    }

    /// Esc closes the slash popup (including the `/skills` list) by clearing the
    /// command; otherwise Esc behaves normally.
    private func dismissSlashPopup() -> Bool {
        guard !slashSpecs.isEmpty || SlashParser.isSkillsListMode(draft) else { return false }
        draft = ""
        return true
    }

    /// Up/Down within the slash popup. Returns true (consumes the key) only while the
    /// popup is open, so arrows behave normally for ordinary text.
    private func moveSlashSelection(_ delta: Int) -> Bool {
        guard !slashSpecs.isEmpty else { return false }
        slashSelection = min(max(0, clampedSlashSelection + delta), slashSpecs.count - 1)
        return true
    }

    /// Applies a picked slash command: argument commands leave the cursor ready to
    /// type the argument; argument-less commands run immediately.
    private func applySuggestion(_ spec: SlashParser.Spec) {
        if spec.takesArg {
            draft = "/\(spec.token) "
        } else {
            draft = "/\(spec.token)"
            send()
        }
    }

    /// Pending-queue strip: one removable chip per message waiting to send (§3.3).
    private var queueStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                ForEach(Array(pendingQueue.enumerated()), id: \.offset) { index, text in
                    HStack(spacing: 6) {
                        Text(text)
                            .font(Theme.metric(11))
                            .foregroundStyle(Theme.textMid)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button {
                            pendingQueue.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from queue")
                        .accessibilityLabel("Remove queued message")
                    }
                    .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
                    .background(Theme.amberFillLo, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line))
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .hideScrollIndicators()
        }
    }

    /// Live context usage for the gauge (§1.6): the last turn's server-reported total
    /// (or an estimate of the active path before any turn) plus the draft being typed,
    /// so the bar projects what the next request will cost and moves as you type.
    private var estimatedContextUsed: Int {
        let base = conversation.contextTokensUsed ?? TokenEstimator.estimate(pathMessages)
        return base + TokenEstimator.estimate(draft)
    }

    /// Busy while a reply streams or the model is being loaded for it, so a second
    /// Send during a slow load queues instead of starting a parallel turn.
    private var isStreaming: Bool { session?.isStreaming == true || isLoadingModel }
    /// Enabled whenever there's something to send — during streaming a send is queued
    /// (§3.3) rather than blocked.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }
    /// Amber gradient when the send/stop button is active, otherwise a flat fill.
    private var sendButtonBackground: AnyShapeStyle {
        (canSend || isStreaming) ? AnyShapeStyle(Theme.sendGradient) : AnyShapeStyle(Theme.fillHi)
    }

    // MARK: Composer

    /// True once the chat has any messages — the point past which the system
    /// prompt (and therefore the persona) is fixed.
    private var chatHasHistory: Bool { !conversation.messages.isEmpty }

    /// SF Symbol for the chat's current persona, matched by name; falls back to
    /// a generic person glyph when there's no persona or its symbol is invalid.
    private var activePersonaIcon: String {
        guard let name = conversation.personaName,
              let match = personas.first(where: { $0.name == name }) else { return "person" }
        return NSImage(systemSymbolName: match.icon, accessibilityDescription: nil) != nil ? match.icon : "person"
    }

    /// Persona control above the input. A chat's system prompt is set once, at
    /// the start, so the picker is editable only on an empty chat and becomes a
    /// static label afterward. Hidden in project chats — those own their prompt —
    /// and when turned off in Settings.
    @ViewBuilder private var personaBar: some View {
        if showPersonaBar && conversation.projectPath == nil {
            HStack(spacing: 8) {
                if chatHasHistory {
                    HStack(spacing: 5) {
                        Image(systemName: activePersonaIcon)
                            .font(.system(size: 10))
                        Text(conversation.personaName ?? "No persona")
                            .font(Theme.label(10))
                    }
                    .foregroundStyle(Theme.textDim)
                    .help("The persona is set before the first message and can't be changed after.")
                } else {
                    Menu {
                        Button { setPersona(nil) } label: {
                            if conversation.personaName == nil {
                                Label("None", systemImage: "checkmark")
                            } else {
                                Text("None")
                            }
                        }
                        if !personas.isEmpty { Divider() }
                        ForEach(personas) { persona in
                            Button { setPersona(persona) } label: {
                                if conversation.personaName == persona.name {
                                    Label(persona.name, systemImage: "checkmark")
                                } else {
                                    Text(persona.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: activePersonaIcon)
                                .font(.system(size: 10))
                            Text(conversation.personaName ?? "Persona")
                                .font(Theme.label(10))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(conversation.personaName != nil ? Theme.amber : Theme.textDim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .panel(Theme.fill, radius: 7,
                               stroke: conversation.personaName != nil ? Theme.amber.opacity(0.4) : Theme.line)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Set this chat's persona (before the first message)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// Apply a persona to the (empty) chat by copying its system prompt, or clear
    /// it for "None". `personaName` is kept only for the picker's label.
    private func setPersona(_ persona: Persona?) {
        conversation.systemPrompt = persona?.systemPrompt
        conversation.personaName = persona?.name
        context.saveOrLog()
    }

    private var composer: some View {
        VStack(spacing: 0) {
            personaBar
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 10) {
                attachFileButton
                if pickedModel?.model.supportsVision == true {
                    attachButton
                }
                ComposerField(text: $draft, height: $composerHeight,
                              isFocused: $composerFocused,
                              placeholder: "Message…  (⇧⏎ for newline)",
                              fontSize: messageFontSize,
                              onSubmit: submitComposer,
                              onMoveUp: { moveSlashSelection(-1) },
                              onMoveDown: { moveSlashSelection(1) },
                              onTab: acceptSlashSuggestion,
                              onCancel: dismissSlashPopup,
                              onPasteImage: pasteImage)
                    .frame(height: composerHeight)
                    .onChange(of: draft) { old, new in
                        slashSelection = 0
                        // Rescan skills as a `/` command starts, so Settings changes and
                        // newly installed skills apply without reopening the chat.
                        if new.hasPrefix("/") && !old.hasPrefix("/") {
                            enabledSkills = SkillSettings.enabledSkills()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .panel(Theme.fill,
                           radius: Theme.Radius.field,
                           stroke: composerFocused ? Theme.amber : Theme.line)

                // Live token estimate for the message being typed (§1.6).
                if !draft.isEmpty {
                    Text("~\(TokenEstimator.estimate(draft)) tok")
                        .font(.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                        .help("Estimated tokens in this message")
                        .padding(.bottom, 9)
                }

                Button(action: isStreaming ? stop : send) {
                    Group {
                        if isStreaming {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.windowBG)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.windowBG)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(sendButtonBackground, in: Circle())
                    .shadow(color: canSend || isStreaming ? Theme.amber.opacity(0.5) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isStreaming)
                .help(isStreaming ? "Stop generating (Esc)" : "Send message")
                .accessibilityLabel(isStreaming ? "Stop generating" : "Send message")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .onDrop(of: [UTType.image], isTargeted: $isDragTarget) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .center) {
            if isDragTarget {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.amber.opacity(0.5), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Attachment strip — thumbnails with remove buttons

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    ZStack(alignment: .topTrailing) {
                        if att.isImage {
                            if let img = NSImage(data: att.data) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
                            }
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: fileSystemImage(for: att.fileName))
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.amber)
                                Text(att.fileName)
                                    .font(.mono(9))
                                    .foregroundStyle(Theme.textMid)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 68)
                            }
                            .frame(width: 72, height: 56)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
                        }

                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                        .accessibilityLabel("Remove attachment")
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .hideScrollIndicators()
        }
    }

    private var attachButton: some View {
        Button(action: pickImages) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("Attach images (vision model)")
        .accessibilityLabel("Attach images")
    }

    private var attachFileButton: some View {
        Button(action: pickFiles) {
            Image(systemName: "paperclip")
                .font(.system(size: 16))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("Attach a file — text, code, PDF, CSV, JSON, notebooks…")
        .accessibilityLabel("Attach a file")
    }

    // MARK: Image picking and drop handling

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .gif, .webP, .heif, .heic]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url),
                  let data = Self.normalizeImageData(image) else { continue }
            let baseName = url.deletingPathExtension().lastPathComponent
            pendingAttachments.append(MessageAttachment(
                data: data,
                mimeType: "image/jpeg",
                fileName: baseName + ".jpg"
            ))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let nsImage = obj as? NSImage,
                          let data = Self.normalizeImageData(nsImage) else { return }
                    let att = MessageAttachment(data: data, mimeType: "image/jpeg", fileName: "image.jpg")
                    Task { @MainActor in pendingAttachments.append(att) }
                }
            }
        }
        return true
    }

    /// Paste (⌘V) an image from the clipboard as a pending chat attachment, e.g. a
    /// screenshot just captured to the clipboard — hands it to the vision path.
    private func pasteImage(_ image: NSImage) -> Bool {
        guard let data = Self.normalizeImageData(image) else {
            flash("Couldn't paste that image.")
            return true
        }
        pendingAttachments.append(MessageAttachment(data: data, mimeType: "image/jpeg", fileName: "image.jpg"))
        composerFocused = true
        return true
    }

    /// Draws `image` into an explicit RGBA8 sRGB CGBitmapContext so the stored
    /// data is always in a pixel format CoreGraphics can handle without errors.
    /// Source images with non-standard layouts (e.g. 3-component RGB padded to
    /// 32 bpp) cause CGBitmapContextCreateWithData failures on every SwiftUI
    /// re-render; normalizing at ingestion time eliminates that entirely.
    /// Transparent areas are composited over white. Dimensions are capped at
    /// 2048 px on the long edge for vision-model compatibility.
    private static func normalizeImageData(_ image: NSImage, maxSide: CGFloat = 2048) -> Data? {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }

        let scale = min(1.0, min(maxSide / src.width, maxSide / src.height))
        let w = Int((src.width  * scale).rounded())
        let h = Int((src.height * scale).rounded())

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }

        // White background so transparent pixels don't go black in JPEG output.
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let normalized = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: normalized)
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
        return rep.representation(using: .jpeg, properties: props)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heif", "heic": return "image/heif"
        default:            return "image/jpeg"
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = []
        panel.title = "Attach a file"
        panel.message = "Text, code, PDF, CSV, JSON, notebooks…"
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            if Self.binaryAttachmentExtensions.contains(ext) {
                flash(".\(ext) files cannot be attached — binary format not supported.")
                continue
            }
            guard let content = FileTextExtractor.extract(url: url) else {
                flash("Could not read \(url.lastPathComponent).")
                continue
            }
            pendingAttachments.append(MessageAttachment(
                data: Data(content.utf8),
                mimeType: textMimeType(for: url),
                fileName: url.lastPathComponent
            ))
        }
    }

    private func textMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":                                return "application/pdf"
        case "json", "jsonl", "ipynb":             return "application/json"
        case "csv", "tsv":                         return "text/csv"
        case "yaml", "yml":                        return "application/yaml"
        case "xml":                                return "application/xml"
        case "md", "rst":                          return "text/markdown"
        case "html":                               return "text/html"
        case "py":                                 return "text/x-python"
        case "js", "ts", "jsx", "tsx":            return "text/javascript"
        case "swift":                              return "text/x-swift"
        case "go":                                 return "text/x-go"
        case "rs":                                 return "text/x-rust"
        case "java", "kt":                         return "text/x-java"
        case "c", "cpp", "cc", "cxx", "h", "hpp": return "text/x-c"
        case "rb":                                 return "text/x-ruby"
        case "cs":                                 return "text/x-csharp"
        case "php":                                return "text/x-php"
        case "sql":                                return "application/sql"
        case "sh", "bash", "zsh":                 return "application/x-sh"
        default:                                   return "text/plain"
        }
    }

    /// Maps a file extension to an SF Symbol name for the attachment chip icon.
    private func fileSystemImage(for fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "pdf":                                              return "doc.richtext"
        case "csv", "tsv":                                       return "tablecells"
        case "json", "jsonl", "ipynb":                           return "curlybraces"
        case "md", "rst", "txt":                                 return "doc.text"
        case "yaml", "yml", "toml", "env", "ini":               return "gear"
        case "sql":                                              return "cylinder"
        case "sh", "bash", "zsh":                               return "terminal"
        case "log":                                              return "list.bullet.rectangle"
        case "patch", "diff":                                    return "arrow.left.arrow.right"
        case "py", "js", "ts", "jsx", "tsx", "swift", "go", "rs",
             "java", "kt", "c", "cpp", "cc", "cxx", "h", "hpp", "rb", "cs", "php": return "chevron.left.forwardslash.chevron.right"
        default:                                                 return "doc"
        }
    }

    // MARK: Session plumbing (unchanged behavior)

    private func ensureSession(grabFocus: Bool = true) {
        // Reuse a session already streaming for this conversation (the user came back
        // to a chat whose turn kept running while they were away).
        guard session == nil else { return }
        if grabFocus { composerFocused = true }
        let keychain = KeychainStore()
        var tools: [any Tool] = []
        if let key = keychain.get(account: FirecrawlClient.keychainAccount), !key.isEmpty {
            let fc = FirecrawlClient(apiKey: key)
            tools = [FirecrawlScrapeTool(client: fc), FirecrawlSearchTool(client: fc)]
        }
        // Include tools from any connected MCP servers.
        tools += mcpManager.availableTools
        tools.append(CurrentTimeTool())
        // First-party filesystem/shell tools. A project-scoped conversation (started from
        // the Projects sidebar) confines them to that project directory; otherwise they're
        // opt-in and confined to the user's chosen global workspace.
        // Guard on fileExists so a stale/moved path doesn't leave the model told it has
        // access while the tool registry is actually empty.
        if let path = conversation.projectPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            tools += FSToolSettings.tools(enabled: true, shell: shellToolEnabled, root: path)
        } else {
            tools += FSToolSettings.tools(enabled: fsToolsEnabled, shell: shellToolEnabled, root: fsToolsRoot)
        }
        // Expose the skills switched on in Settings ▸ Skills via a use_skill tool (§3.7).
        let skills = SkillSettings.enabledSkills()
        if !skills.isEmpty { tools.append(UseSkillTool(skills: skills)) }
        // Persistent memory (opt-in, Settings ▸ Memory). Project chats get both scopes.
        var memoryScopes: [MemoryScope] = [.global]
        if let path = conversation.projectPath, !path.isEmpty { memoryScopes.append(.project(path: path)) }
        if memoryEnabled {
            tools += [SaveMemoryTool(scopes: memoryScopes), ReadMemoryTool(scopes: memoryScopes)]
        }
        // The memory flag is snapshotted here so the injected index and the registered
        // tools always agree (never a prompt commanding tools that aren't offered).
        // Toggling Settings ▸ Memory invalidates all sessions via ContentView, so open
        // chats rebuild against the new setting on their next message. The file listing
        // itself stays live per round — a memory saved in round 1 is in the prompt from
        // round 2 with no rebuild.
        let staticSuffix = combinedSystemSuffix
        let includeMemory = memoryEnabled
        let session = ChatSession(client: LMStudioClient.shared, context: context,
                                  recorder: UsageRecorder(context: context),
                                  keychain: keychain,
                                  registry: ToolRegistry(tools),
                                  systemSuffix: { toolsActive in
                                      let memoryIndex = includeMemory
                                          ? MemoryStore.indexInjection(scopes: memoryScopes,
                                                                       toolsAvailable: toolsActive) : nil
                                      let parts = [staticSuffix, memoryIndex].compactMap(\.self).filter { !$0.isEmpty }
                                      return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
                                  },
                                  maxToolRounds: effectiveMaxRounds,
                                  yoloMode: effectiveYolo)
        // Notify when a reply finishes and the user has moved to another chat/app.
        // `conversation` is read at completion time so the title/snippet are current.
        let id = convoID
        session.onTurnCompleted = { [notifier, conversation] in
            let reply = conversation.activePath().last { $0.role == .assistant }?.content ?? ""
            notifier.replyFinished(conversation: id, title: conversation.title ?? "", snippet: reply)
        }
        sessionStore.setSession(session, for: convoID)
    }

    /// Stops the current streaming turn on demand (the composer's stop button).
    private func stop() {
        sessionStore.cancelTask(for: convoID)
    }

    /// Opens a folder picker and saves the chosen path as this chat's workspace.
    /// The session is rebuilt so the file tools are registered with the new root.
    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Workspace"
        panel.message = "Choose the folder the model can read and write on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        conversation.projectPath = url.path
        context.saveOrLog()
        rebuildSession()
    }

    /// Clears the workspace so the model loses local file access for this chat.
    private func clearWorkspace() {
        conversation.projectPath = nil
        context.saveOrLog()
        rebuildSession()
    }

    /// Discards the current session and recreates it so a workspace change (or any
    /// other registry change) takes effect immediately without reopening the chat.
    private func rebuildSession() {
        sessionStore.discard(convoID)
        // Don't steal focus — the user may be in a popover or other control.
        ensureSession(grabFocus: false)
    }

    /// Drops a past user turn back into the composer (focused) so it can be edited
    /// and resent. Resending forks a new sibling branch from this message (§1.2).
    private func reuseDraft(_ message: Message) {
        editingSource = message
        // Re-prefix a skill turn so resending re-invokes the skill (and keeps its chip).
        if let name = message.skillName {
            draft = message.content.isEmpty ? "/\(name) " : "/\(name) \(message.content)"
        } else {
            draft = message.content
        }
        composerFocused = true
    }

    /// Switches the conversation to a sibling branch by re-selecting its active leaf
    /// (the tail of that branch's subtree). Wired to MessageRow's ◀ k/n ▶ control.
    private func selectBranch(_ leaf: Message) {
        conversation.activeLeaf = leaf
        context.saveOrLog()
    }

    // MARK: Slash commands (§3.1)

    private func handleSlash(_ command: SlashCommand) {
        switch command {
        case .help:
            flash(SlashParser.helpText)
        case .clear:
            // Irreversible, and one Return from the slash popup — require a repeat.
            guard let armed = clearArmedAt, Date().timeIntervalSince(armed) < 6 else {
                clearArmedAt = Date()
                flash("This deletes every message. Run /clear again within 6 seconds to confirm.")
                return
            }
            clearArmedAt = nil
            for message in conversation.messages { context.delete(message) }
            conversation.messages.removeAll()
            conversation.summary = nil
            conversation.summaryThroughData = nil
            conversation.activeLeafData = nil
            context.saveOrLog()
            flash("Cleared this conversation.")
        case .export:
            if let url = ConversationExporter.writeToDownloads(conversation) {
                flash("Exported to ~/Downloads/\(url.lastPathComponent)")
            } else {
                flash("Couldn't export — check Downloads permissions.")
            }
        case .skills, .skill:
            break   // `/skills` opens the list via send(); `/<skill>` is sent as a message
        case .compact:
            guard let session, let server = boundServer else { flash("Pick a model first."); return }
            guard !isStreaming else { flash("Wait for the current reply to finish."); return }
            flash("Compacting earlier turns…")
            Task {
                switch await session.compact(conversation, server: server) {
                case .compacted(let n): flash("Compacted \(n) earlier turn\(n == 1 ? "" : "s") into a summary.")
                case .nothingToCompact: flash("Nothing to compact yet — this chat is still short.")
                case .failed:           flash("Couldn’t compact right now.")
                }
            }
        case .copy:
            if let last = conversation.activePath().last(where: { $0.role == .assistant && !$0.content.isEmpty }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.content, forType: .string)
                flash("Copied the last response.")
            } else {
                flash("No response to copy yet.")
            }
        case .temperature(let value):
            let clamped = min(max(value, 0), 2)
            conversation.temperature = clamped
            context.saveOrLog()
            flash(String(format: "Temperature set to %.2f for this chat.", clamped))
        case .system(let prompt):
            conversation.systemPrompt = prompt.isEmpty ? nil : prompt
            context.saveOrLog()
            flash(prompt.isEmpty ? "Cleared the system prompt." : "System prompt updated.")
        case .model(let query):
            if let match = discovered.first(where: {
                $0.model.id.localizedCaseInsensitiveContains(query)
                    || $0.model.familyName.localizedCaseInsensitiveContains(query)
            }) {
                pickedModel = match
                conversation.modelID = match.model.id
                conversation.serverID = match.server.id
                context.saveOrLog()
                flash("Switched to \(match.model.familyName).")
            } else {
                flash("No model matches “\(query)”.")
            }
        }
    }

    /// Shows a transient one-line confirmation in the composer area, auto-clearing.
    private func flash(_ message: String) {
        commandFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if commandFeedback == message { commandFeedback = nil }
        }
    }

    /// Re-runs an assistant turn on a fresh sibling branch (§1.3). No-ops while a
    /// turn is already streaming.
    private func regenerate(_ message: Message) {
        guard let session, !isStreaming else { return }
        bindPickedModel()
        guard let server = boundServer else {
            session.errorText = "Pick a model before regenerating."
            return
        }
        let id = convoID
        // Regenerating is an explicit action — snap to the new turn even if
        // the user had scrolled away to read history.
        isNearBottom = true
        sessionStore.setTask(Task {
            let window = await ensureLoaded() ?? contextWindow
            await session.regenerate(message, in: conversation, server: server,
                                     serverOnline: registry.isOnline(server),
                                     modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                                     sampling: effectiveSampling, contextWindow: window)
            sessionStore.setTask(nil, for: id)
            drainQueue()
        }, for: id)
    }

    /// Loads the picked LM Studio model, with Modelo's context cap, when it isn't loaded
    /// yet — otherwise LM Studio loads it on first request at its own default, which can
    /// be "model maximum" (Devstral at 393K, out of GPU memory). Best-effort: on failure
    /// the turn still runs and LM Studio's error surfaces as usual.
    ///
    /// - Returns: The context window to use for this turn when a load happened (the
    ///   live entry can't reflect it until the next monitor poll), else nil.
    private func ensureLoaded() async -> Int? {
        guard let live = discovered.first(where: { $0.id == pickedModel?.id }),
              live.server.kind == .lmStudio, !live.model.isLoaded,
              let onModelSelect else { return nil }
        isLoadingModel = true
        defer { isLoadingModel = false }
        guard await onModelSelect(live) else { return nil }
        return live.server.contextLength(for: live.model.id)
            ?? LMStudioLoadContext.contextLength(for: live.model)
    }

    /// Why sending to `server` can't work right now, or nil when it can (or is still
    /// being probed — we don't block on "unknown").
    private func unavailableReason(for server: Server) -> String? {
        switch registry.status(for: server) {
        case .offline: "\(server.label) is offline. Your draft is kept — pick another model, or send once it's back."
        case .needsKey: "\(server.label) needs an API key. Add one in Settings, then send."
        case .online, .unknown: nil
        }
    }

    /// True when the last turn failed: the path ends on a user message with no reply.
    private var canRetry: Bool {
        !isStreaming && conversation.activePath().last?.role == .user
    }

    /// Re-runs the failed turn against the currently picked server.
    private func retry() {
        guard let session, canRetry else { return }
        bindPickedModel()
        guard let server = boundServer else {
            session.errorText = "Pick a model before retrying."
            return
        }
        isNearBottom = true
        let id = convoID
        sessionStore.setTask(Task {
            let window = await ensureLoaded() ?? contextWindow
            await session.retry(in: conversation, server: server,
                                serverOnline: registry.isOnline(server),
                                modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                                sampling: effectiveSampling, contextWindow: window)
            sessionStore.setTask(nil, for: id)
            drainQueue()
        }, for: id)
    }

    /// Sends the next queued message once the current turn finishes (§3.3).
    private func drainQueue() {
        guard !isStreaming, !pendingQueue.isEmpty else { return }
        draft = pendingQueue.removeFirst()
        send()
    }

    private func send() {
        // The session may have been invalidated by a settings change (e.g. the memory
        // toggle) since this view appeared — rebuild it lazily rather than dropping
        // the send.
        ensureSession()
        guard let session else { return }
        // Slash commands (§3.1) are handled locally, never sent to the model — except
        // `/<skill>`, which is sent as a skill-tagged message below (§3.7).
        let parsed = SlashParser.parse(draft, skillNames: enabledSkills.map(\.name))
        if let command = parsed {
            if case .skill = command {} else {
                handleSlash(command)
                // `/skills` reopens the pickable list rather than clearing the composer.
                draft = command == .skills ? "/skills " : ""
                return
            }
        }
        // While a reply streams, queue the message instead of sending now (§3.3).
        if isStreaming {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // The queue is text-only, so an attachment-only draft can't be queued —
                // tell the user instead of silently swallowing the Send.
                if !pendingAttachments.isEmpty {
                    flash("Finish the current reply before sending attachments.")
                }
                return
            }
            pendingQueue.append(text)
            draft = ""
            flash("Queued — sends when the current reply finishes.")
            return
        }
        // Bind to the header's picked model FIRST, so the resolved server and the
        // modelID sent always agree (otherwise a just-switched model can route to the
        // previously-bound server).
        bindPickedModel()
        // No model/server resolved yet (e.g. a conversation bound to an offline
        // server with nothing picked). Surface it instead of silently no-op'ing.
        guard let server = boundServer else {
            session.errorText = "Pick a model before sending."
            return
        }
        // Don't consume the draft for a send that can't happen: the session would
        // refuse an offline server only after `draft` was already cleared.
        if unavailableReason(for: server) != nil { return }
        var text = draft
        var skill: AgentSkill?
        if case .skill(let name, let request)? = parsed,
           let found = enabledSkills.first(where: { $0.name == name }) {
            // A skill too big for the model's window would fail on every later turn
            // too, so refuse up front and keep the draft (§3.7).
            let wanted = found.instructions + "\n\n" + request
            if !TokenEstimator.fits(wanted, contextWindow: contextWindow) {
                flash("\"\(name)\" is ~\(TokenEstimator.estimate(wanted).formatted()) tokens — too big for this model's \(contextWindow.formatted())-token context.")
                return
            }
            skill = found
            text = request
        }
        let attachments = pendingAttachments
        let edited = editingSource
        draft = ""
        pendingAttachments = []
        editingSource = nil
        let id = convoID
        // Sending is an explicit action — snap to the new turn even if the
        // user had scrolled away to read history.
        isNearBottom = true
        sessionStore.setTask(Task {
            let window = await ensureLoaded() ?? contextWindow
            await session.send(text, attachments: attachments, in: conversation, server: server,
                               serverOnline: registry.isOnline(server),
                               modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                               sampling: effectiveSampling, contextWindow: window,
                               skill: skill, replacing: edited)
            sessionStore.setTask(nil, for: id)
            drainQueue()
        }, for: id)
    }
}

/// One row in the slash-command autocomplete popup (§3.1): the command, its
/// optional argument hint, and a summary, with a hover highlight.
private struct SlashSuggestionRow: View {
    let spec: SlashParser.Spec
    let isHighlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("/\(spec.token)")
                    .font(Theme.code(12, weight: .medium))
                    .foregroundStyle(Theme.amber)
                if let arg = spec.arg {
                    Text(arg)
                        .font(Theme.code(11))
                        .foregroundStyle(Theme.textDim)
                }
                Text(spec.summary)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.textLo)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering || isHighlighted ? Theme.fillHi : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


private extension ChatView {
    static let binaryAttachmentExtensions: Set<String> = [
        "parquet", "pkl", "arrow", "xlsx", "docx", "pptx",
        "zip", "gz", "tar", "bin", "exe", "dmg", "mp4", "mov"
    ]
}

/// Confirmation card for a mutating file/shell tool call or a gated MCP tool. Shows
/// what the model wants to do (write/edit a file, run a command, call an MCP server
/// with these arguments) and waits for Approve / Deny.
private struct ToolApprovalCard: View {
    let pending: ChatSession.PendingApproval
    let onDecision: (ChatSession.ApprovalDecision) -> Void

    private var icon: String {
        switch pending.preview.kind {
        case .write: "square.and.pencil"
        case .edit:  "pencil.and.outline"
        case .shell: "terminal"
        case .external: "puzzlepiece.extension"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                Text(pending.preview.title)
                    .font(Theme.metric(12))
                    .foregroundStyle(Theme.textHi)
                Spacer(minLength: 0)
                Text(pending.toolName)
                    .font(.mono(10))
                    .foregroundStyle(Theme.textDim)
            }
            ScrollView {
                Text(pending.preview.detail)
                    .font(Theme.code(11))
                    .foregroundStyle(Theme.textMid)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .hideScrollIndicators()
            }
            .frame(maxHeight: 160)
            .background(Theme.consoleBG, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.line))

            // macOS dialog order: the alternate choice on the leading edge, Cancel
            // directly left of the default button on the trailing edge.
            HStack(spacing: 8) {
                // Hidden where ChatSession wouldn't honor it, rather than silently
                // downgrading the click to a one-off approval.
                if pending.preview.allowsSessionGrant {
                    Button("Approve for session", action: { onDecision(.session) })
                        .buttonStyle(ApprovalButtonStyle(kind: .secondary))
                        .help("Run \(pending.toolName) without asking again for the rest of this chat")
                }
                Spacer(minLength: 0)
                Button("Deny", action: { onDecision(.deny) })
                    .buttonStyle(ApprovalButtonStyle(kind: .plain))
                Button("Approve once", action: { onDecision(.once) })
                    .buttonStyle(ApprovalButtonStyle(kind: .primary))
            }
        }
        .padding(11)
        .background(Theme.amberFillLo, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.amberBorder))
    }
}

/// One look for the approval card's buttons, with hover and press feedback (each was
/// hand-styled on `.plain` before, so none of them reacted to the pointer).
private struct ApprovalButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        ApprovalButtonLabel(configuration: configuration, kind: kind)
    }
}

/// Split out so it can hold hover state — a `ButtonStyle` itself can't.
private struct ApprovalButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let kind: ApprovalButtonStyle.Kind
    @State private var hovering = false

    private var foreground: Color {
        switch kind {
        case .primary:   Theme.windowBG
        case .secondary: Theme.amber
        case .plain:     Theme.textLo
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary:   AnyShapeStyle(Theme.sendGradient)
        case .secondary: AnyShapeStyle(Theme.amberFillLo)
        case .plain:     AnyShapeStyle(Theme.fill)
        }
    }

    private var border: Color {
        switch kind {
        case .primary:   .clear
        case .secondary: Theme.amberBorder
        case .plain:     Theme.line
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .font(kind == .primary ? Theme.metric(12).weight(.semibold) : Theme.metric(12))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .primary ? 14 : 12)
            .padding(.vertical, 5)
            .background(fill, in: shape)
            .overlay(shape.stroke(border))
            .brightness(hovering && !configuration.isPressed ? 0.06 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// Whether the chat keeps following new output, decided from the real scroll position.
enum ScrollFollow {
    /// Within this distance of the end counts as "at the bottom".
    static let bottomSlack: CGFloat = 40

    /// Any scroll up stops following; reaching the bottom resumes it. Content growing
    /// below the viewport (a streaming reply) leaves the offset alone, so it doesn't count.
    /// A user's scroll up pauses even inside `bottomSlack`: small nudges there used to
    /// keep following on, and auto-scroll pulled the reader back between gestures.
    static func isFollowing(was: Bool, oldOffsetY: CGFloat, newOffsetY: CGFloat,
                            distanceFromBottom: CGFloat, userScrolling: Bool = false) -> Bool {
        let movedUp = newOffsetY < oldOffsetY - 0.5
        if userScrolling && movedUp { return false }
        if distanceFromBottom <= bottomSlack { return true }
        if movedUp { return false }
        return was
    }
}

/// The transcript's row stack. macOS 15+ lays every message out exactly: a lazy stack
/// estimates unloaded rows, and a long reply estimated ~1,300pt off flipped the content
/// height back and forth several times a second while streaming (logged 2026-10-28),
/// making scrolling jumpy, the scroll thumb jump, and the end overscroll into blank space.
/// macOS 14 keeps the lazy stack, whose bottom-sentinel visibility it needs for following.
/// ponytail: eager layout of every turn; add a "show earlier messages" cutoff if very
/// long chats get slow to open.
private struct TranscriptStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15, *) {
            VStack(alignment: .leading, spacing: 10) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: 10) { content }
        }
    }
}

/// Feeds the transcript's scroll position into `ScrollFollow` (macOS 15+; macOS 14
/// keeps the bottom-sentinel fallback in `messageStream`).
private struct FollowsScrollPosition: ViewModifier {
    @Binding var isNearBottom: Bool
    @Binding var userScrolling: Bool

    private struct Sample: Equatable {
        var offsetY: CGFloat
        var distanceFromBottom: CGFloat
        var contentHeight: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Sample.self) { g in
                Sample(offsetY: g.contentOffset.y,
                       distanceFromBottom: g.contentSize.height - g.visibleRect.maxY,
                       contentHeight: g.contentSize.height)
            } action: { old, new in
                let following = ScrollFollow.isFollowing(was: isNearBottom, oldOffsetY: old.offsetY,
                                                         newOffsetY: new.offsetY,
                                                         distanceFromBottom: new.distanceFromBottom,
                                                         userScrolling: userScrolling)
                // Write only on a real change: this runs inside layout, and a write on every
                // geometry tick fed a layout loop until AppKit threw ("more Update Constraints
                // passes than there are views", 2026-10-28).
                if following != isNearBottom {
                    isNearBottom = following
                    // SCROLLDIAG (temporary): which rule flipped following, and where.
                    Log.chat.notice("SCROLLDIAG follow -> \(following) offset \(Int(old.offsetY))->\(Int(new.offsetY)) fromBottom \(Int(new.distanceFromBottom)) userScrolling \(userScrolling)")
                }
                // SCROLLDIAG — temporary evidence for the jumping-thumb / blank-overscroll
                // bug. Remove once that's fixed.
                if old.contentHeight != new.contentHeight {
                    Log.chat.notice("SCROLLDIAG height \(Int(old.contentHeight)) -> \(Int(new.contentHeight)) offset \(Int(new.offsetY)) fromBottom \(Int(new.distanceFromBottom))")
                }
            }
            // The user's own gesture (and its momentum), as opposed to programmatic
            // scrolls, which report `.idle` or `.animating`.
            .onScrollPhaseChange { _, phase in
                let byUser: Bool
                switch phase {
                case .tracking, .interacting, .decelerating: byUser = true
                default: byUser = false
                }
                if byUser != userScrolling {
                    userScrolling = byUser
                    Log.chat.notice("SCROLLDIAG phase \(String(describing: phase)) userScrolling \(byUser)")
                }
            }
        } else {
            content
        }
    }
}
