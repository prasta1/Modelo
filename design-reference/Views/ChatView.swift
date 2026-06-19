import SwiftUI

/// Chat screen (handoff §5): context bar → messages → composer.
struct ChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ContextBar()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(store.messages) { MessageRow(message: $0) }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }

            composer
        }
        .background(Theme.windowBG)
    }

    // MARK: Composer (handoff §5.3)

    private var composer: some View {
        @Bindable var store = store
        return VStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Message Modelo…", text: $store.composerDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1...6)

                HStack(spacing: 12) {
                    Image(systemName: "paperclip")
                    Image(systemName: "photo")

                    HStack(spacing: 7) {
                        Circle().fill(Theme.green).frame(width: 5, height: 5)
                        Text(store.selectedModel?.name ?? "—")
                            .font(.mono(11)).foregroundStyle(Theme.textLo)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 7))

                    Spacer(minLength: 0)

                    Text("⌘↵ to send").font(.mono(10)).foregroundStyle(Theme.textFaint)
                    sendButton
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.textMute)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                .stroke(Color.white.opacity(0.09)))
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14).padding(.bottom, 22)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x1A1206))
                .frame(width: 30, height: 30)
                .background(Theme.sendGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)   // ⌘↵ send; ⇧↵ newline is default
    }

    private func send() {
        let text = store.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.messages.append(ChatMessage(role: .user, text: text))
        store.composerDraft = ""
        // Real send wires into ChatSession / the streaming provider.
    }
}
