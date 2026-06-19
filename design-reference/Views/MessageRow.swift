import SwiftUI

/// One chat turn (handoff §5.2). User turns are right-aligned bubbles; assistant
/// turns get a header, an optional tool-call chip, body text, and either a
/// metrics footer or a streaming caret.
struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:      userBubble
        case .assistant: assistantTurn
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 0)
            Text(message.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.textHi)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.fill, in: bubbleShape)
                .overlay(bubbleShape.stroke(Theme.line))
        }
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: Theme.Radius.bubble,
            bottomLeadingRadius: Theme.Radius.bubble,
            bottomTrailingRadius: Theme.Radius.bubble,
            topTrailingRadius: Theme.Radius.bubbleTight   // tightened top-right corner
        )
    }

    // MARK: Assistant

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(spacing: 8) {
                ModeloMark(size: 13)
                Text(message.modelName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                if message.isStreaming {
                    Text("streaming").font(.mono(10)).foregroundStyle(Theme.green)
                } else if !message.timestamp.isEmpty {
                    Text(message.timestamp).font(.mono(10)).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.bottom, 11)

            if let tool = message.toolCall {
                InlineChip(icon: tool.systemImage, title: tool.title, detail: tool.detail)
                    .padding(.bottom, 14)
            }

            // body (+ inline streaming caret)
            if message.isStreaming {
                HStack(alignment: .bottom, spacing: 2) {
                    bodyText
                    BlinkingCaret()
                }
            } else {
                bodyText
            }

            if let metrics = message.metrics {
                metricsRow(metrics).padding(.top, 15)
            }
        }
    }

    private var bodyText: some View {
        Text(message.text)
            .font(.system(size: 14))
            .lineSpacing(6)                 // line-height ~1.72
            .foregroundStyle(Theme.textMid)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metricsRow(_ m: MessageMetrics) -> some View {
        HStack(spacing: 16) {
            Text(m.ttft); Text(m.rate); Text(m.tokens)
            Spacer(minLength: 0)
            Text("Copy").foregroundStyle(Theme.textDim)
            Text("Regenerate").foregroundStyle(Theme.textDim)
        }
        .font(.mono(10))
        .foregroundStyle(Theme.textFaint)
    }
}

/// Reusable tool-call / web-search chip (handoff §5).
struct InlineChip: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textLo)
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.textLo)
            Text(detail).font(.mono(10.5)).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.02),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .stroke(Color.white.opacity(0.07)))
    }
}

/// Blinking amber caret for the streaming assistant turn.
struct BlinkingCaret: View {
    @State private var visible = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.amber)
            .frame(width: 7, height: 15)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { visible = false }
            }
    }
}
