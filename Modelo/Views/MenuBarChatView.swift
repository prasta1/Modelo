import SwiftUI
import SwiftData

/// A lightweight chat message for the menu bar popover (not persisted to SwiftData).
struct QuickMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
}

/// Quick-chat conversation state, owned by the app and shared by the menu-bar
/// dropdown and its popped-out window, so undocking carries the conversation
/// (and any reply still streaming) across instead of starting empty.
@MainActor
@Observable
final class QuickChatSession {
    var pickedModel: DiscoveredModel?
    var draft = ""
    private(set) var messages: [QuickMessage] = []
    private(set) var streamingText = ""
    private(set) var isStreaming = false
    var errorText: String?
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private let client = LMStudioClient.shared

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pickedModel != nil
            && !isStreaming
    }

    /// Clears the conversation, cancelling any reply in flight.
    func newChat() {
        streamTask?.cancel()
        messages = []
        streamingText = ""
        isStreaming = false
        errorText = nil
    }

    /// Cancels the reply in flight; any partial text is kept as a message.
    func stop() { streamTask?.cancel() }

    /// Sends the draft to the picked model and streams the reply into `streamingText`.
    func send() {
        guard let model = pickedModel else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        draft = ""
        errorText = nil
        messages.append(QuickMessage(role: .user, content: text))
        isStreaming = true
        streamingText = ""

        // Snapshot history before the new user message for the API call.
        let historyMessages = messages.dropLast().map { Message(role: $0.role, content: $0.content) }
        let userWireMessage = Message(role: .user, content: text)

        streamTask = Task { @MainActor in
            let endpoint = Endpoint(server: model.server, keychain: keychain)
            do {
                let stream = client.streamChat(
                    endpoint: endpoint,
                    modelID: model.model.id,
                    messages: historyMessages + [userWireMessage],
                    systemPrompt: "",
                    sampling: SamplingParams(temperature: 0.7),
                    tools: nil
                )
                for try await event in stream {
                    switch event {
                    case .delta(let token): streamingText += token
                    // e.g. Apple Intelligence trimmed old turns to fit its context.
                    case .notice(let text): errorText = text
                    case .usage, .toolCalls: break
                    }
                }
            } catch is CancellationError {
                // User tapped stop — leave partial text in messages if any.
            } catch {
                Log.chat.error("Menu-bar chat stream failed: \(error.localizedDescription, privacy: .public)")
                errorText = error.localizedDescription
            }

            let finished = streamingText
            streamingText = ""
            isStreaming = false
            if !finished.isEmpty {
                messages.append(QuickMessage(role: .assistant, content: finished))
            }
            streamTask = nil
        }
    }
}

/// Compact chat attached to the menu bar extra icon. Intended for quick one-off
/// exchanges without switching focus to the main window. Also hosted in the
/// resizable "Quick Chat" window when popped out of the menu bar.
struct MenuBarChatView: View {
    /// True when hosted in the popped-out window rather than the menu-bar
    /// dropdown: the view then fills the resizable window instead of using the
    /// dropdown's fixed size, and hides the pop-out button.
    var isDetached = false

    @Environment(\.modelContext) private var context
    @Environment(ServerRegistry.self) private var registry
    @Environment(QuickChatSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    @State private var discovered: [DiscoveredModel] = []

    // View ▸ text-size commands (⌘+/⌘−) drive this value; 15 pt is "Actual Size".
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15

    /// Zoom factor relative to the default text size, so the quick-chat composer
    /// tracks the View ▸ text-size commands while keeping its compact 13 pt base.
    private var textScale: CGFloat { messageFontSize / 15 }

    private let keychain = KeychainStore()

    var body: some View {
        // `@Bindable` turns the environment's observable session into `$` bindings.
        @Bindable var session = session
        VStack(spacing: 0) {
            QuickChatToolbar(
                discovered: discovered,
                pickedModel: $session.pickedModel,
                onNewChat: session.newChat,
                onOpenModelo: openInModelo,
                onPopOut: isDetached ? nil : popOut
            )
            Divider().overlay(Theme.Palette.strokeStrong)
            QuickChatMessageList(
                messages: session.messages,
                streamingText: session.streamingText,
                isStreaming: session.isStreaming,
                hasModel: session.pickedModel != nil
            )
            if let err = session.errorText {
                Text(err)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.Palette.alert)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.panel)
            }
            Divider().overlay(Theme.Palette.strokeStrong)
            QuickChatComposer(
                draft: $session.draft,
                isStreaming: session.isStreaming,
                canSend: session.canSend,
                textScale: textScale,
                onSend: session.send,
                onStop: session.stop
            )
        }
        // nil leaves the popped-out window free to resize.
        .frame(width: isDetached ? nil : 380, height: isDetached ? nil : 480)
        .background(Theme.Palette.bg)
        .task { await fetchModels() }
    }

    // MARK: Actions

    private func openInModelo() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Undocks the quick chat into its own resizable window. Activating the app
    /// makes that window key, which dismisses the menu-bar dropdown.
    private func popOut() {
        openWindow(id: ModeloApp.quickChatWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fetchModels() async {
        let targets = servers.filter { registry.isOnline($0) && !$0.isPaused }
            .map { (server: $0, endpoint: Endpoint(server: $0, keychain: keychain)) }

        var result: [DiscoveredModel] = []
        await withTaskGroup(of: [DiscoveredModel].self) { group in
            for target in targets {
                let ep = target.endpoint
                let srv = target.server
                group.addTask {
                    let models = (try? await LMStudioClient.shared.fetchModels(endpoint: ep)) ?? []
                    return models.map { DiscoveredModel(server: srv, model: $0) }
                }
            }
            for await batch in group { result.append(contentsOf: batch) }
        }

        discovered = result
        // Auto-select the first loaded model, or the first model available.
        if session.pickedModel == nil || !result.contains(where: { $0.model.id == session.pickedModel?.model.id }) {
            session.pickedModel = result.first(where: { $0.model.isLoaded }) ?? result.first
        }
    }
}

// MARK: - Toolbar

private struct QuickChatToolbar: View {
    let discovered: [DiscoveredModel]
    @Binding var pickedModel: DiscoveredModel?
    let onNewChat: () -> Void
    let onOpenModelo: () -> Void
    /// Pops the chat out into its own window; nil hides the button (already popped out).
    let onPopOut: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if discovered.isEmpty {
                Text("no servers online")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.Palette.inkFaint)
            } else {
                // Same searchable, endpoint-grouped popover as the main window, so a
                // large cloud catalog stays behind search instead of one flat menu.
                // No load/eject/new-chat hooks: quick chat only picks.
                ModelPickerView(discovered: discovered, selection: $pickedModel,
                                onModelSelect: nil, onModelEject: nil, onNewChat: nil)
            }
            Spacer()
            Button { onNewChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
            .buttonStyle(.plain)
            .help("New chat")
            if let onPopOut {
                Button { onPopOut() } label: {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.inkFaint)
                }
                .buttonStyle(.plain)
                .help("Pop out into a resizable window")
            }
            Button { onOpenModelo() } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
            .buttonStyle(.plain)
            .help("Open Modelo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.Palette.panel)
    }
}

// MARK: - Message List

private struct QuickChatMessageList: View {
    let messages: [QuickMessage]
    let streamingText: String
    let isStreaming: Bool
    let hasModel: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty && !isStreaming {
                        QuickChatEmptyState(hasModel: hasModel)
                    }
                    ForEach(messages) { msg in
                        QuickMessageRow(msg: msg)
                    }
                    if isStreaming {
                        if streamingText.isEmpty {
                            BlinkingCursor()
                                .padding(.horizontal, 40)
                                .padding(.vertical, 8)
                        } else {
                            QuickMessageRow(msg: QuickMessage(role: .assistant, content: streamingText))
                        }
                    }
                    Color.clear.frame(height: 1).id("scroll-bottom")
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: streamingText) { proxy.scrollTo("scroll-bottom") }
            .onChange(of: messages.count) { proxy.scrollTo("scroll-bottom", anchor: .bottom) }
        }
    }
}

// MARK: - Empty State

private struct QuickChatEmptyState: View {
    let hasModel: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text(hasModel ? "Ask anything…" : "Pick a model above to start")
                .font(Theme.metric(12))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

// MARK: - Composer

private struct QuickChatComposer: View {
    @Binding var draft: String
    let isStreaming: Bool
    let canSend: Bool
    let textScale: CGFloat
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.bg.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.Palette.stroke, lineWidth: 1)
                        )
                )
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        draft += "\n"
                        return .handled
                    }
                    if canSend { onSend() }
                    return .handled
                }

            Button {
                if isStreaming { onStop() } else { onSend() }
            } label: {
                Group {
                    if isStreaming {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Palette.bg)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.Palette.bg)
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    canSend || isStreaming ? Theme.Palette.signal : Theme.Palette.panelHigh,
                    in: Circle()
                )
                .shadow(color: canSend || isStreaming ? Theme.Palette.signal.opacity(0.45) : .clear, radius: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isStreaming)
            .help(isStreaming ? "Stop generating" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Palette.panel)
    }
}

// MARK: - Message row

private struct QuickMessageRow: View {
    let msg: QuickMessage

    // Same key the main-window MessageRow reads, so both chats zoom together.
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15

    private var textScale: CGFloat { messageFontSize / 15 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == .assistant {
                Image(systemName: "cpu")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.signal)
                    .frame(width: 16, height: 16)
                    .background(Theme.Palette.signal.opacity(0.12), in: Circle())
                    .padding(.top, 1)
            }

            Text(msg.content)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(msg.role == .user ? Theme.Palette.inkDim : Theme.Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
                .multilineTextAlignment(msg.role == .user ? .trailing : .leading)

            if msg.role == .user {
                Circle()
                    .fill(Theme.Palette.panelHigh)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.Palette.inkFaint)
                    }
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
