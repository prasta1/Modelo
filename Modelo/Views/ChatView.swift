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
    @Environment(\.modelContext) private var context

    @State private var session: ChatSession?
    @State private var sendTask: Task<Void, Never>?
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
    // First-party filesystem/shell tools — opt-in, off by default (Settings ▸ Tools).
    @AppStorage(FSToolSettings.enabledKey) private var fsToolsEnabled = false
    @AppStorage(FSToolSettings.shellKey)   private var shellToolEnabled = false
    @AppStorage(FSToolSettings.rootKey)    private var fsToolsRoot = ""
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @State private var showSampling = false
    @State private var showBenchmark = false


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
                    try? context.save()
                }
            }
        )
    }

    private var contextWindow: Int {
        pickedModel?.model.maxContextLength ?? 0
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
        .onDisappear { cancelInFlight() }
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
                Spacer(minLength: 8)
                if let server = pickedModel?.server {
                    statusPill(for: server)
                }
                artifactsButton
                samplingButton
                benchmarkButton
                FontSizeControl(size: $messageFontSize)
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
                    Button("Reset") { conversation.samplingOverride = SamplingParams(); try? context.save() }
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
            .onChange(of: conversation.samplingOverride) { try? context.save() }
            .onChange(of: conversation.autoCompact) { try? context.save() }
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

    /// Applies a preset's system prompt (if any) and sampling overrides to this chat.
    private func apply(_ preset: Preset) {
        conversation.apply(preset)
        try? context.save()
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

    private var composer: some View {
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 10) {
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
                    .padding(.vertical, 11)
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

    // MARK: Session plumbing (unchanged behavior)

    private func ensureSession() {
        guard session == nil else { return }
        let keychain = KeychainStore()
        var tools: [any Tool] = []
        if let key = keychain.get(account: FirecrawlClient.keychainAccount), !key.isEmpty {
            let fc = FirecrawlClient(apiKey: key)
            tools = [FirecrawlScrapeTool(client: fc), FirecrawlSearchTool(client: fc)]
        }
        // Include tools from any connected MCP servers.
        tools += mcpManager.availableTools
        // First-party filesystem/shell tools — opt-in, confined to the chosen workspace.
        tools += FSToolSettings.tools(enabled: fsToolsEnabled, shell: shellToolEnabled, root: fsToolsRoot)
        // Expose ~/.agents skills via a use_skill tool (§3.7).
        let skills = AgentsLoader.loadSkills()
        if !skills.isEmpty { tools.append(UseSkillTool(skills: skills)) }
        session = ChatSession(client: LMStudioClient.shared, context: context,
                              recorder: UsageRecorder(context: context),
                              keychain: keychain,
                              registry: ToolRegistry(tools),
                              systemSuffix: artifactsEnabled ? ArtifactInstructions.system : nil)
        composerFocused = true
    }

    /// Cancels any in-flight streaming + titling when this view goes away (the
    /// user switched conversations), so abandoned work doesn't run to completion.
    private func cancelInFlight() {
        sendTask?.cancel()
        session?.cancelPendingWork()
    }

    /// Stops the current streaming turn on demand (the composer's stop button).
    private func stop() {
        sendTask?.cancel()
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
        try? context.save()
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
            try? context.save()
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
            try? context.save()
            flash(String(format: "Temperature set to %.2f for this chat.", clamped))
        case .system(let prompt):
            conversation.systemPrompt = prompt.isEmpty ? nil : prompt
            try? context.save()
            flash(prompt.isEmpty ? "Cleared the system prompt." : "System prompt updated.")
        case .model(let query):
            if let match = discovered.first(where: {
                $0.model.id.localizedCaseInsensitiveContains(query)
                    || $0.model.familyName.localizedCaseInsensitiveContains(query)
            }) {
                pickedModel = match
                conversation.modelID = match.model.id
                conversation.serverID = match.server.id
                try? context.save()
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
        sendTask = Task {
            await session.regenerate(message, in: conversation, server: server,
                                     serverOnline: registry.isOnline(server),
                                     modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                                     sampling: effectiveSampling, contextWindow: contextWindow)
            sendTask = nil
            drainQueue()
        }
    }

    /// Sends the next queued message once the current turn finishes (§3.3).
    private func drainQueue() {
        guard !isStreaming, !pendingQueue.isEmpty else { return }
        draft = pendingQueue.removeFirst()
        send()
    }

    private func send() {
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
            guard !text.isEmpty else { return }
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
        sendTask = Task {
            await session.send(text, attachments: attachments, in: conversation, server: server,
                               serverOnline: registry.isOnline(server),
                               modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                               sampling: effectiveSampling, contextWindow: contextWindow,
                               replacing: edited)
            sendTask = nil
            drainQueue()
        }
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

/// A−/A+ stepper for the chat text size. Clamped to a sane range; the same value
/// is also driven by the ⌘+ / ⌘- / ⌘0 menu commands.
struct FontSizeControl: View {
    @Binding var size: Double

    static let range: ClosedRange<Double> = 12...26

    var body: some View {
        HStack(spacing: 0) {
            button("textformat.size.smaller") {
                size = max(Self.range.lowerBound, size - 1)
            }
            Rectangle().fill(Theme.Palette.stroke).frame(width: 1, height: 16)
            button("textformat.size.larger") {
                size = min(Self.range.upperBound, size + 1)
            }
        }
        .panel(Theme.Palette.panel, radius: 7)
        .help("Chat text size (⌘+ / ⌘−)")
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.inkDim)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
