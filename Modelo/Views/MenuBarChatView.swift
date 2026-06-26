import SwiftUI
import SwiftData

/// A lightweight chat message for the menu bar popover (not persisted to SwiftData).
private struct QuickMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
}

/// Compact chat popover attached to the menu bar extra icon. Intended for quick
/// one-off exchanges without switching focus to the main window.
struct MenuBarChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(ServerRegistry.self) private var registry
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    @State private var discovered: [DiscoveredModel] = []
    @State private var pickedModel: DiscoveredModel?
    @State private var draft = ""
    @State private var messages: [QuickMessage] = []
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var errorText: String?

    private let keychain = KeychainStore()
    private let client = LMStudioClient.shared

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pickedModel != nil
            && !isStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.Palette.strokeStrong)
            messageList
            if let err = errorText {
                Text(err)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.Palette.alert)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.panel)
            }
            Divider().overlay(Theme.Palette.strokeStrong)
            composer
        }
        .frame(width: 380, height: 480)
        .background(Theme.Palette.bg)
        .task { await fetchModels() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Eyebrow("Quick Chat")
            Spacer()
            if discovered.isEmpty {
                Text("no servers online")
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.Palette.inkFaint)
            } else {
                modelPicker
            }
            Button { newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
            .buttonStyle(.plain)
            .help("New chat")
            Button { openInModelo() } label: {
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

    private var modelPicker: some View {
        Menu {
            ForEach(discovered, id: \.model.id) { item in
                Button {
                    pickedModel = item
                } label: {
                    HStack {
                        Text(item.model.displayName)
                        if pickedModel?.model.id == item.model.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pickedModel?.model.displayName ?? "pick model")
                    .font(Theme.metric(11))
                    .foregroundStyle(pickedModel == nil ? Theme.Palette.inkFaint : Theme.Palette.inkDim)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick a model")
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty && !isStreaming {
                        emptyState
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
            .onChange(of: streamingText) { proxy.scrollTo("scroll-bottom") }
            .onChange(of: messages.count) { proxy.scrollTo("scroll-bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text(pickedModel == nil ? "Pick a model above to start" : "Ask anything…")
                .font(Theme.metric(12))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
                    if canSend { send() }
                    return .handled
                }

            Button {
                if isStreaming { streamTask?.cancel() } else { send() }
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

    // MARK: Actions

    private func newChat() {
        streamTask?.cancel()
        messages = []
        streamingText = ""
        isStreaming = false
        errorText = nil
    }

    private func openInModelo() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func send() {
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
                    if case .delta(let token) = event { streamingText += token }
                }
            } catch is CancellationError {
                // User tapped stop — leave partial text in messages if any.
            } catch {
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

    private func fetchModels() async {
        let targets = servers.filter { registry.isOnline($0) }
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
        if pickedModel == nil || !result.contains(where: { $0.model.id == pickedModel?.model.id }) {
            pickedModel = result.first(where: { $0.model.isLoaded }) ?? result.first
        }
    }
}

// MARK: - Message row

private struct QuickMessageRow: View {
    let msg: QuickMessage

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
                .font(.system(size: 13))
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
