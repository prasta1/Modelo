import SwiftUI
import AppKit

/// One chat turn, Native Refined (handoff §5.2). Your turns are right-aligned
/// bubbles (tight top-right corner). The model's turns are full-width: a
/// `ModeloMark` + model-name header, body text, any tool-call cards, and a
/// metrics footer (tok/s · tokens) with copy / share actions.
struct MessageRow: View {
    let message: Message
    /// Model label shown in the assistant header (the conversation's model id).
    var modelName: String = ""
    /// Invoked with the message text when "edit & resend" is tapped on the user's
    /// own turn; ChatView drops it back into the composer. Nil hides the action.
    var onReuse: ((String) -> Void)? = nil
    /// When true, renders body as plain text (streaming in progress); switches to
    /// MarkdownText on completion so Markdown isn't re-parsed on every token.
    var isStreaming: Bool = false
    // Shared with the composer and the View menu; default kept in sync across sites.
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if message.role == .tool {
            ToolCard(title: "🔧 \(message.toolName ?? "tool")", detail: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isUser {
            userTurn
        } else {
            assistantTurn
        }
    }

    // MARK: User — right-aligned bubble

    private var userTurn: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                userBubble
                hoverBar
            }
        }
        .onHover { hovering = $0 }
    }

    private var userBubble: some View {
        let imageAtts = message.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if !imageAtts.isEmpty { attachmentThumbs(imageAtts) }
            Text(message.content)
                .font(.system(size: messageFontSize))
                .lineSpacing(messageFontSize * 0.22)
                .foregroundStyle(Theme.textHi)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.fill, in: userBubbleShape)
        .overlay(userBubbleShape.stroke(Theme.line))
    }

    /// A subtle speech-tail: the corner nearest the speaker (top-right) is tightened.
    private var userBubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: Theme.Radius.bubble,
            bottomLeadingRadius: Theme.Radius.bubble,
            bottomTrailingRadius: Theme.Radius.bubble,
            topTrailingRadius: Theme.Radius.bubbleTight,
            style: .continuous
        )
    }

    // MARK: Assistant — full-width turn

    private var assistantTurn: some View {
        let calls = message.toolCallsJSON.flatMap { ToolCall.decodeList($0) } ?? []
        let imageAtts = message.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ModeloMark(size: 13)
                Text(modelName.isEmpty ? "Assistant" : modelName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Text(Theme.timeFormatter.string(from: message.createdAt))
                    .font(.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.bottom, 11)

            if !imageAtts.isEmpty {
                attachmentThumbs(imageAtts).padding(.bottom, 10)
            }

            // Empty assistant content (pre-first-token) shows the blinking caret.
            if message.content.isEmpty && calls.isEmpty {
                BlinkingCursor()
            } else if !message.content.isEmpty {
                if isStreaming {
                    Text(message.content)
                        .font(.system(size: messageFontSize))
                        .lineSpacing(messageFontSize * 0.3)
                        .foregroundStyle(Theme.textMid)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownText(content: message.content)
                }
            }

            if !calls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        ToolCard(title: "🔧 \(call.name)(…)", detail: call.arguments, language: "json")
                    }
                }
                .padding(.top, message.content.isEmpty ? 0 : 12)
            }

            if !message.content.isEmpty {
                metricsRow.padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachmentThumbs(_ atts: [MessageAttachment]) -> some View {
        HStack(spacing: 4) {
            ForEach(atts) { att in
                if let img = NSImage(data: att.data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: Assistant metrics footer (always shown once the turn has content)

    private var metricsRow: some View {
        HStack(spacing: 16) {
            if let tps = message.tokensPerSecond {
                Text(String(format: "%.0f tok/s", tps))
            }
            if let tokens = message.tokenCount {
                Text("\(tokens) tok")
            }
            Spacer(minLength: 0)
            Button(action: copy) {
                Text(copied ? "Copied" : "Copy")
                    .foregroundStyle(copied ? Theme.green : Theme.textDim)
            }
            .buttonStyle(.plain)
            ShareLink(item: message.content) {
                Text("Share").foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .font(.mono(10))
        .monospacedDigit()
        .foregroundStyle(Theme.textFaint)
    }

    // MARK: User hover row — actions + telemetry

    private var hoverBar: some View {
        HStack(spacing: 8) {
            Text(metaLine)
                .font(.mono(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
            if !message.content.isEmpty { actionCluster }
        }
        .padding(.horizontal, 2)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// "142 tok/s · 13:05" — shown on hover only.
    private var metaLine: String {
        var parts: [String] = []
        if let tps = message.tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        parts.append(Theme.timeFormatter.string(from: message.createdAt))
        return parts.joined(separator: " · ")
    }

    private var actionCluster: some View {
        HStack(spacing: 1) {
            iconButton(copied ? "checkmark" : "doc.on.doc",
                       help: "Copy",
                       tint: copied ? Theme.green : Theme.textMute,
                       action: copy)
            shareButton
            if let onReuse {
                iconButton("arrow.uturn.up", help: "Edit & resend") { onReuse(message.content) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Theme.fillHi, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
    }

    private func iconButton(_ symbol: String, help: String,
                            tint: Color = Theme.textMute,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 22, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Native macOS share menu, styled to match the other action icons.
    private var shareButton: some View {
        ShareLink(item: message.content) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMute)
                .frame(width: 22, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Share")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copied = true
        // Flip the icon back to the copy glyph after a beat.
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// Collapsible card for a tool call or result. Collapsed by default.
private struct ToolCard: View {
    let title: String
    let detail: String
    /// Explicit language hint for syntax highlighting. Pass nil to auto-detect JSON.
    var language: String? = nil
    @State private var expanded = false

    /// Sniffs the content for JSON if no language is supplied.
    private var effectiveLanguage: String? {
        if let language { return language }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? "json" : nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ModeloHighlighter.shared
                .highlightCode(detail, language: effectiveLanguage)
                .font(Theme.code(11))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(Theme.code(10))
                .foregroundStyle(Theme.textDim)
        }
        .padding(8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
    }
}
