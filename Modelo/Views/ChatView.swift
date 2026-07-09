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
    @Environment(ServerRegistry.self) private var registry
    @Environment(MCPServerManager.self) private var mcpManager
    @Environment(ChatSessionStore.self) private var sessionStore
    @Environment(ChatNotifier.self) private var notifier
    @Environment(\.modelContext) private var context

    @State private var draft = ""
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var isDragTarget = false
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
    /// below `minChatWidth`. Seeded wide to avoid a first-layout squeeze.
    @State private var detailWidth: CGFloat = 1200
    private let minChatWidth: Double = 360
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
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @Query(sort: \Persona.sortOrder) private var personas: [Persona]
    @State private var showSampling = false
    @State private var showBenchmark = false
    @State private var showAgentControls = false
    /// Reference to the AppKit view behind the chat column, resolved at click time
    /// by the screenshot button to capture exactly what's on screen.
    @State private var snapshotProbe = SnapshotProbeView.Holder()
    @State private var pendingSnapshot: SnapshotItem?

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

    private var contextWindow: Int {
        boundServer?.contextLength(for: pickedModel?.model.id ?? "") ?? pickedModel?.model.maxContextLength ?? 0
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

    /// Artifact panel width clamped so the chat never shrinks below `minChatWidth`.
    private var clampedArtifactWidth: Double {
        min(max(artifactPanelWidth, 320), max(360, Double(detailWidth) - minChatWidth))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                messageStream
                footer
            }
            .frame(maxWidth: .infinity)
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
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .animation(.easeOut(duration: 0.18), value: openArtifactID == nil)
        .background(Theme.windowBG)
        .onAppear { ensureSession() }
        // No .onDisappear cancel: a turn keeps streaming after the user leaves the
        // chat, so multiple conversations can run at once (the store owns it).
        // Keep an open chat's tool-call cap and YOLO mode in sync with the Settings
        // values and the per-chat overrides (agent popover).
        .onChange(of: effectiveMaxRounds) { session?.maxToolRounds = effectiveMaxRounds }
        .onChange(of: effectiveYolo) { session?.yoloMode = effectiveYolo }
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
        .onChange(of: artifactGroups.count) { _, count in
            if count > 0, let newest = artifactGroups.last { openArtifactID = newest.id }
        }
        .sheet(item: $pendingSnapshot) { item in
            SnapshotPreviewView(url: item.url)
        }
    }

    // MARK: Header — model spec plate + live status

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ModelPickerView(discovered: discovered, selection: pickedModelBinding, onModelSelect: onModelSelect, onModelEject: onModelEject)
                if pickedModel?.model.supportsToolUse == true {
                    Toggle("Tools", isOn: $conversation.toolsEnabled)
                        .toggleStyle(ChipToggleStyle())
                        .help("Allow this model to call tools")
                }
                workspaceButton
                artifactsButton
                samplingButton
                if pickedModel?.model.supportsToolUse == true {
                    agentButton
                }
                benchmarkButton
                screenshotButton
                Spacer(minLength: 8)
                if let server = pickedModel?.server {
                    statusPill(for: server)
                }
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
            Text(live ? "LIVE" : status == .offline ? "OFFLINE" : "PROBING")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(live ? Theme.green : Theme.textMute)
            Text(server.label)
                .font(.mono(10))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
    }

    /// Per-conversation sampling overrides (§1.4b) — a popover with the shared
    /// controls plus a one-tap "apply preset". Amber when this chat overrides defaults.
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
                    // Cap so the chat keeps at least minChatWidth in view.
                    let maxW = max(360, Double(detailWidth) - minChatWidth)
                    artifactPanelWidth = min(max(base - value.translation.width, 320), maxW)
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
            .help(open ? "Hide artifacts (\(artifactGroups.count))" : "Show artifacts (\(artifactGroups.count))")
        }
    }

    private var samplingButton: some View {
        let overriding = conversation.samplingOverride != SamplingParams()
        return Button { showSampling.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .foregroundStyle(overriding ? Theme.amber : Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Sampling for this chat")
        .popover(isPresented: $showSampling, arrowEdge: .bottom) {
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
                }
                SamplingControls(params: Binding(get: { conversation.samplingOverride },
                                                 set: { conversation.samplingOverride = $0 }))
                Text("Overrides the global defaults from Settings for this chat only.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)

                Divider().overlay(Theme.line)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-compact long chats").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                        Text("Summarize older turns near the context limit (§1.5).")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    PillToggle(isOn: $conversation.autoCompact)
                }
            }
            .padding(16)
            .frame(width: 320)
            .onChange(of: conversation.samplingOverride) { context.saveOrLog() }
            .onChange(of: conversation.autoCompact) { context.saveOrLog() }
        }
    }

    /// Per-chat agent behavior: the YOLO switch and the tool-call limit override.
    /// Red when YOLO is effective, amber when only the limit is overridden.
    private var agentButton: some View {
        let tint: Color = effectiveYolo ? Theme.Palette.alert
            : conversation.maxToolRoundsOverride != nil ? Theme.amber
            : Theme.Palette.inkDim
        return Button { showAgentControls.toggle() } label: {
            Image(systemName: "bolt")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Tool approvals and limit for this chat")
        .popover(isPresented: $showAgentControls, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow("Agent · this chat")
                    Spacer()
                    Button("Reset") {
                        conversation.yoloEnabled = false
                        conversation.maxToolRoundsOverride = nil
                        context.saveOrLog()
                    }
                    .font(Theme.metric(11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
                    .help("Turn off YOLO and use the global tool-call limit")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOLO mode").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                        Text("Run writes, edits and shell commands without asking; no tool-call limit.")
                            .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    PillToggle(isOn: globalYolo ? .constant(true) : $conversation.yoloEnabled)
                        .disabled(globalYolo)
                }
                if globalYolo {
                    Text("Enabled globally in Settings ▸ Tools.")
                        .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                }
                Divider().overlay(Theme.line)
                Stepper(value: Binding(get: { conversation.maxToolRoundsOverride ?? maxToolRounds },
                                       set: { conversation.maxToolRoundsOverride = $0 == maxToolRounds ? nil : $0 }),
                        in: 1...20) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max tool calls per turn").font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                            Text("Overrides the Settings default for this chat only.")
                                .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
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
            .padding(16)
            .frame(width: 320)
            .onChange(of: conversation.yoloEnabled) { context.saveOrLog() }
            .onChange(of: conversation.maxToolRoundsOverride) { context.saveOrLog() }
        }
    }

    /// Opens the load-test sheet for the picked model (§2.5).
    private var benchmarkButton: some View {
        Button { showBenchmark = true } label: {
            Image(systemName: "stopwatch")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Benchmark a model")
        .disabled(discovered.isEmpty)
        .sheet(isPresented: $showBenchmark) {
            BenchmarkView(discovered: discovered, initial: pickedModel)
        }
    }

    /// Captures the chat column as a share-ready PNG card: what's currently on
    /// screen, on a themed backdrop with a caption. Saved to ~/Downloads and
    /// copied to the clipboard.
    private var screenshotButton: some View {
        Button { takeScreenshot() } label: {
            Image(systemName: "camera")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .panel(Theme.Palette.panel, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Screenshot this chat — opens a share-ready preview")
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

    /// Shows the active workspace as an amber chip (tap to change, ✕ to clear),
    /// or a folder+ button when no workspace is set. Lets the model on the
    /// remote server read/write files on this Mac.
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
        } else {
            Button(action: pickWorkspace) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkDim)
                    .frame(width: 30, height: 26)
                    .panel(Theme.Palette.panel, radius: 7)
            }
            .buttonStyle(.plain)
            .help("Set a local folder the model can read and write on this Mac")
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
                        LazyVStack(alignment: .leading, spacing: 10) {
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
                                ).id(msg.id)
                            }
                            Color.clear.frame(height: 1).id(bottomAnchor)
                        }
                        .padding(20)
                        // Bottom-align short conversations so the latest turn sits just
                        // above the composer rather than stranding it under a void.
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
                    }
                }
                .scrollIndicators(.hidden)
                .hideScrollIndicators()
                // Scroll to bottom when a new message is appended.
                .onChange(of: conversation.messages.count) { scrollToBottom(proxy) }
                // Timer-based scroll during streaming: fires at ~20fps instead of once
                // per token, avoiding layout-pass spam from per-character onChange.
                .task(id: session?.isStreaming) {
                    guard session?.isStreaming == true else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        scrollToBottom(proxy)
                    }
                    scrollToBottom(proxy)
                }
            }
        }
    }

    /// Fills the message area before the first turn so a fresh chat reads as
    /// intentional empty space, not a dead gap above the composer.
    private var emptyConversationHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text(pickedModel == nil
                 ? "Pick a model above, then say something."
                 : "Send a message to \(pickedModel!.model.familyName) to begin.")
                .font(.mono(12))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private let bottomAnchor = "BOTTOM"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    // MARK: Footer — error, context gauge, composer

    private var footer: some View {
        VStack(spacing: 0) {
            if let error = session?.errorText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.alert)
                    Text(error)
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.Palette.alert)
                    Spacer(minLength: 0)
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

            // Mutating tool call awaiting the user's go-ahead (file/shell tools).
            if let pending = session?.pendingApproval {
                ToolApprovalCard(pending: pending,
                                 onDecision: { session?.respondToApproval($0) })
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

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
        if !specs.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                    SlashSuggestionRow(spec: spec,
                                       isHighlighted: index == clampedSlashSelection) {
                        applySuggestion(spec)
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

    /// Slash suggestions for the current draft, and the clamped keyboard highlight.
    private var slashSpecs: [SlashParser.Spec] { SlashParser.suggestions(for: draft) }
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

    private var isStreaming: Bool { session?.isStreaming == true }
    /// Enabled whenever there's something to send — during streaming a send is queued
    /// (§3.3) rather than blocked.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
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
    /// static label afterward. Hidden in project chats — those own their prompt.
    @ViewBuilder private var personaBar: some View {
        if conversation.projectPath == nil {
            HStack(spacing: 8) {
                if chatHasHistory {
                    HStack(spacing: 5) {
                        Image(systemName: activePersonaIcon)
                            .font(.system(size: 10))
                        Text(conversation.personaName ?? "No persona")
                            .font(Theme.label(10))
                    }
                    .foregroundStyle(Theme.textFaint)
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
                              onMoveDown: { moveSlashSelection(1) })
                    .frame(height: composerHeight)
                    .onChange(of: draft) { slashSelection = 0 }
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
                        .foregroundStyle(Theme.textFaint)
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
                .help(isStreaming ? "Stop generating" : "Send message")
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
                        if let img = NSImage(data: att.data) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
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
    }

    // MARK: Image picking and drop handling

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .gif, .webP, .heif, .heic]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            pendingAttachments.append(MessageAttachment(
                data: data,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            ))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let nsImage = obj as? NSImage,
                          let tiff = nsImage.tiffRepresentation,
                          let bmp = NSBitmapImageRep(data: tiff),
                          let png = bmp.representation(using: .png, properties: [:]) else { return }
                    let att = MessageAttachment(data: png, mimeType: "image/png", fileName: "image.png")
                    Task { @MainActor in pendingAttachments.append(att) }
                }
            }
        }
        return true
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

        let binaryExtensions: Set<String> = [
            "parquet", "pkl", "arrow", "xlsx", "docx", "pptx",
            "zip", "gz", "tar", "bin", "exe", "dmg", "mp4", "mov"
        ]

        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            if binaryExtensions.contains(ext) {
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
        // Expose ~/.agents skills via a use_skill tool (§3.7).
        let skills = AgentsLoader.loadSkills()
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
        draft = message.content
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
        case .skills:
            let skills = AgentsLoader.loadSkills()
            flash(skills.isEmpty
                  ? "No skills found in ~/.agents/skills."
                  : "\(skills.count) skills available: \(skills.map(\.name).joined(separator: ", "))")
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
        sessionStore.setTask(Task {
            await session.regenerate(message, in: conversation, server: server,
                                     serverOnline: registry.isOnline(server),
                                     modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                                     sampling: effectiveSampling, contextWindow: contextWindow)
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
        // Slash commands (§3.1) are handled locally, never sent to the model.
        if let command = SlashParser.parse(draft) {
            handleSlash(command)
            draft = ""
            return
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
        let text = draft
        let attachments = pendingAttachments
        let edited = editingSource
        draft = ""
        pendingAttachments = []
        editingSource = nil
        let id = convoID
        sessionStore.setTask(Task {
            await session.send(text, attachments: attachments, in: conversation, server: server,
                               serverOnline: registry.isOnline(server),
                               modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                               sampling: effectiveSampling, contextWindow: contextWindow,
                               replacing: edited)
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

/// Confirmation card for a mutating file/shell tool call. Shows what the model wants
/// to do (write/edit a file, run a command) and waits for Approve / Deny.
private struct ToolApprovalCard: View {
    let pending: ChatSession.PendingApproval
    let onDecision: (ChatSession.ApprovalDecision) -> Void

    private var icon: String {
        switch pending.preview.kind {
        case .write: "square.and.pencil"
        case .edit:  "pencil.and.outline"
        case .shell: "terminal"
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
                    .foregroundStyle(Theme.textFaint)
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

            HStack(spacing: 8) {
                Button("Deny", action: { onDecision(.deny) })
                    .buttonStyle(.plain)
                    .font(Theme.metric(12))
                    .foregroundStyle(Theme.textLo)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                Spacer(minLength: 0)
                Button("Approve for session", action: { onDecision(.session) })
                    .buttonStyle(.plain)
                    .font(Theme.metric(12))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.amberFillLo, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.amberBorder))
                    .help("Run \(pending.toolName) without asking again for the rest of this chat")
                Button("Approve once", action: { onDecision(.once) })
                    .buttonStyle(.plain)
                    .font(Theme.metric(12).weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Theme.sendGradient, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(11)
        .background(Theme.amberFillLo, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.amberBorder))
    }
}
