import SwiftUI
import AppKit

/// One turn as a chat bubble — your messages align right, the model's align left.
/// Hovering reveals quick actions (copy, share, and — on your own turns — edit &
/// resend) alongside the turn's telemetry, so the thread stays clean until you
/// reach for it. The action row reserves its height, so revealing it never shifts
/// the layout.
struct MessageRow: View {
    let message: Message
    /// Invoked with the message text when "edit & resend" is tapped on the user's
    /// own turn; ChatView drops it back into the composer. Nil hides the action.
    var onReuse: ((String) -> Void)? = nil
    // Shared with the composer and the View menu; default kept in sync across sites.
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    /// A subtle speech-tail: the corner nearest the speaker is squared off.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: isUser ? 14 : 4,
            bottomTrailingRadius: isUser ? 4 : 14,
            topTrailingRadius: 14,
            style: .continuous
        )
    }

    private var bubbleFill: Color {
        isUser ? Theme.Palette.signal.opacity(0.16) : Theme.Palette.panel
    }
    private var bubbleStroke: Color {
        isUser ? Theme.Palette.signal.opacity(0.35) : Theme.Palette.stroke
    }

    /// "142 tok/s · 13:05" — shown on hover only.
    private var metaLine: String {
        var parts: [String] = []
        if let tps = message.tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        parts.append(Theme.timeFormatter.string(from: message.createdAt))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if message.role == .tool {
            ToolCard(title: "🔧 \(message.toolName ?? "tool")", detail: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let json = message.toolCallsJSON, let calls = ToolCall.decodeList(json) {
            VStack(alignment: .leading, spacing: 6) {
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: messageFontSize))
                        .foregroundStyle(Theme.Palette.ink)
                        .textSelection(.enabled)
                }
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    ToolCard(title: "🔧 \(call.name)(…)", detail: call.arguments)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubbleRow
        }
    }

    /// A normal user/assistant turn as a left/right-aligned chat bubble.
    private var bubbleRow: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubble
                hoverBar
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        let imageAtts = message.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if !imageAtts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(imageAtts) { att in
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
            if message.content.isEmpty {
                if message.role == .assistant { BlinkingCursor() }
            } else {
                Text(message.content)
                    .font(.system(size: messageFontSize))
                    .lineSpacing(messageFontSize * 0.22)
                    .foregroundStyle(Theme.Palette.ink)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(bubbleFill, in: bubbleShape)
        .overlay(bubbleShape.strokeBorder(bubbleStroke, lineWidth: 1))
    }

    // MARK: Hover row — actions + telemetry

    private var hoverBar: some View {
        HStack(spacing: 8) {
            if !message.content.isEmpty { actionCluster }
            Text(metaLine)
                .font(Theme.metric(9))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .padding(.horizontal, 2)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering) // invisible buttons must not be clickable
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var actionCluster: some View {
        HStack(spacing: 1) {
            iconButton(copied ? "checkmark" : "doc.on.doc",
                       help: "Copy",
                       tint: copied ? Theme.Palette.live : Theme.Palette.inkDim,
                       action: copy)
            shareButton
            if isUser, let onReuse {
                iconButton("arrow.uturn.up", help: "Edit & resend") { onReuse(message.content) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Theme.Palette.panelHigh, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
    }

    private func iconButton(_ symbol: String, help: String,
                            tint: Color = Theme.Palette.inkDim,
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
                .foregroundStyle(Theme.Palette.inkDim)
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
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(detail)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.Palette.inkDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(Theme.label(10))
                .foregroundStyle(Theme.Palette.inkDim)
        }
        .padding(8)
        .panel(Theme.Palette.panel, radius: 8)
    }
}
