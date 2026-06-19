import SwiftUI
import AppKit

/// Menu-bar mini chat — the popover *contents* only (handoff §7). The desktop,
/// menu bar, notch, and vibrancy are all provided by `MenuBarExtra(.window)`.
struct MenuBarChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    // Illustrative mini-turn; the real mini chat shares the conversation store.
    private let bullets = [
        "Runs entirely on local hardware; no data leaves the network.",
        "Routes any prompt to the fastest available server automatically.",
        "Falls back to OpenRouter when a model isn't loaded locally.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            messages
            composer
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 392)
        .background(Theme.popoverBG)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.green).frame(width: 5, height: 5)
                Text(store.selectedModel?.name ?? "—")
                    .font(.mono(11.5)).foregroundStyle(Theme.textHi)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.textMute)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Color.white.opacity(0.07)))

            Spacer()

            HStack(spacing: 14) {
                Image(systemName: "square.and.pencil")
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .font(.system(size: 14)).foregroundStyle(Theme.textMute)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
    }

    // MARK: Messages

    private var messages: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Text("Summarize the selected text in 3 bullets.")
                    .font(.system(size: 13)).lineSpacing(2).foregroundStyle(Theme.textHi)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.fill, in: miniBubble)
                    .overlay(miniBubble.stroke(Theme.line))
            }
            .padding(.bottom, 16)

            HStack(spacing: 7) {
                ModeloMark(size: 12)
                Text(store.selectedModel?.name ?? "—")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textHi)
                Text("now").font(.mono(9.5)).foregroundStyle(Theme.textFaint)
            }
            .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 9) {
                        Text("—").foregroundStyle(Theme.amber)
                        Text(line).foregroundStyle(Theme.textMid)
                    }
                    .font(.system(size: 12.5)).lineSpacing(2)
                }
            }

            HStack(spacing: 14) {
                Text("TTFT 190ms"); Text("48 tok/s")
                Spacer()
                Text("Copy").foregroundStyle(Theme.textDim)
            }
            .font(.mono(9.5)).foregroundStyle(Theme.textFaint)
            .padding(.top, 12)
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
    }

    private var miniBubble: some Shape {
        UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13,
                               bottomTrailingRadius: 13, topTrailingRadius: 5)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            Text("Reply…").font(.system(size: 13)).foregroundStyle(Theme.textDim)
            Spacer()
            Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(Theme.textMute)
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x1A1206))
                .frame(width: 27, height: 27)
                .background(Theme.sendGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .padding(.leading, 13).padding(.trailing, 9).padding(.vertical, 8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.09)))
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 13)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("↩ send · ⇧↩ newline").font(.mono(10)).foregroundStyle(Theme.textFaint)
            Spacer()
            HStack(spacing: 7) {
                Text("Open in Modelo").font(.system(size: 11.5)).foregroundStyle(Theme.textLo)
                Text("⌘O").font(.mono(10)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 5))
            }
            .contentShape(Rectangle())
            .onTapGesture { openMainWindow() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.white.opacity(0.012))
    }

    private func openMainWindow() {
        store.section = .models     // route to the same conversation
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
