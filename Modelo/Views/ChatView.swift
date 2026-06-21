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
    @FocusState private var composerFocused: Bool
    // Adjustable chat text size, shared with MessageRow and the View menu (⌘+ / ⌘-).
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    // Global sampling defaults (JSON-encoded SamplingParams), edited in Settings ▸ Sampling.
    @AppStorage("globalSamplingJSON") private var globalSamplingJSON = "{}"
    @Query(sort: \Preset.sortOrder) private var presets: [Preset]
    @State private var showSampling = false


    /// The server bound to this conversation (matches conversation.serverID).
    private var boundServer: Server? {
        discovered.first { $0.server.id == conversation.serverID }?.server
            ?? pickedModel?.server
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

    var body: some View {
        VStack(spacing: 0) {
            header
            messageStream
            footer
        }
        .background(Theme.windowBG)
        .onAppear { ensureSession() }
        .onDisappear { cancelInFlight() }
    }

    // MARK: Header — model spec plate + live status

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ModelPickerView(discovered: discovered, selection: $pickedModel, onModelSelect: onModelSelect, onModelEject: onModelEject)
                if pickedModel?.model.supportsToolUse == true {
                    Toggle("Tools", isOn: $conversation.toolsEnabled)
                        .toggleStyle(ChipToggleStyle())
                }
                Spacer(minLength: 8)
                if let server = pickedModel?.server {
                    statusPill(for: server)
                }
                samplingButton
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
                    }
                    Button("Reset") { conversation.samplingOverride = SamplingParams(); try? context.save() }
                        .font(Theme.metric(11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textDim)
                }
                SamplingControls(params: Binding(get: { conversation.samplingOverride },
                                                 set: { conversation.samplingOverride = $0 }))
                Text("Overrides the global defaults from Settings for this chat only.")
                    .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
            }
            .padding(16)
            .frame(width: 320)
            .onChange(of: conversation.samplingOverride) { try? context.save() }
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
                                        && msg.id == path.last?.id
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
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

    /// Live context usage for the gauge (§1.6): the last turn's server-reported total
    /// (or an estimate of the active path before any turn) plus the draft being typed,
    /// so the bar projects what the next request will cost and moves as you type.
    private var estimatedContextUsed: Int {
        let base = conversation.contextTokensUsed ?? TokenEstimator.estimate(pathMessages)
        return base + TokenEstimator.estimate(draft)
    }

    private var isStreaming: Bool { session?.isStreaming == true }
    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty) && !isStreaming
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
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: messageFontSize))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1...8)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .panel(Theme.fill,
                           radius: Theme.Radius.field,
                           stroke: composerFocused ? Theme.amber : Theme.line)
                    .focused($composerFocused)
                    .onSubmit(send)

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
        session = ChatSession(client: LMStudioClient.shared, context: context,
                              recorder: UsageRecorder(context: context),
                              keychain: keychain,
                              registry: ToolRegistry(tools))
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

    /// Re-runs an assistant turn on a fresh sibling branch (§1.3). No-ops while a
    /// turn is already streaming.
    private func regenerate(_ message: Message) {
        guard let session, !isStreaming else { return }
        guard let server = boundServer else {
            session.errorText = "Pick a model before regenerating."
            return
        }
        sendTask = Task {
            await session.regenerate(message, in: conversation, server: server,
                                     serverOnline: registry.isOnline(server),
                                     modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                                     sampling: effectiveSampling)
            sendTask = nil
        }
    }

    private func send() {
        guard let session else { return }
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
        // Keep the conversation bound to the chosen model/server.
        if let picked = pickedModel {
            conversation.modelID = picked.model.id
            conversation.serverID = picked.server.id
        }
        sendTask = Task {
            await session.send(text, attachments: attachments, in: conversation, server: server,
                               serverOnline: registry.isOnline(server),
                               modelSupportsTools: pickedModel?.model.supportsToolUse ?? false,
                               sampling: effectiveSampling,
                               replacing: edited)
            sendTask = nil
        }
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
