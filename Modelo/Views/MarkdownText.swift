import SwiftUI
import AppKit
import MarkdownUI
import Highlightr

/// Renders message text as GitHub-flavored Markdown with syntax-highlighted,
/// copyable code blocks, styled to Modelo's instrument theme.
///
/// This replaces the former plain `Text(message.content)` in the assistant turn
/// (MERGE_PLAN §1.1 — Modelo's single most visible gap). Markdown re-parsing is
/// relatively expensive, so the caller renders plain `Text` while a turn is still
/// streaming and swaps to this view once the turn completes.
struct MarkdownText: View {
    let content: String
    var fontSize: CGFloat = 15

    var body: some View {
        Markdown(content)
            .markdownTheme(.modelo(fontSize: fontSize))
            .markdownCodeSyntaxHighlighter(.modelo)
            .textSelection(.enabled)
    }
}

// MARK: - Theme

extension MarkdownUI.Theme {
    /// Modelo's instrument look mapped onto MarkdownUI: warm amber for inline code
    /// and links, `Theme.textMid` body, code blocks on the console surface.
    static func modelo(fontSize: CGFloat) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(Theme.textMid)
                FontSize(fontSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(fontSize * 0.88)
                ForegroundColor(Theme.amber)
                BackgroundColor(Theme.fillHi)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(Theme.amber) }
            .codeBlock { configuration in
                ModeloCodeBlock(configuration: configuration, fontSize: fontSize)
            }
    }
}

/// A fenced code block: a language/copy header over the highlighted, horizontally
/// scrollable source, on the console surface. Mirrors Fornax's per-block copy.
private struct ModeloCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let fontSize: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(Theme.consoleBG, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
        .markdownMargin(top: 8, bottom: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let lang = configuration.language, !lang.isEmpty {
                Text(lang.lowercased())
                    .font(Theme.code(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.code(10))
                    .foregroundStyle(copied ? Theme.green : Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.fillHi)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - Syntax highlighting

/// Bridges Highlightr (highlight.js, 180+ languages) into MarkdownUI. Highlightr
/// spins up a JS context, so a single instance is shared across all code blocks.
struct ModeloSyntaxHighlighter: CodeSyntaxHighlighter {
    /// Built once — fenced blocks render at a fixed mono size independent of the
    /// prose font, matching `Theme.code` usage elsewhere.
    static let shared = ModeloSyntaxHighlighter(fontSize: 13)

    private let highlightr: Highlightr?

    init(fontSize: CGFloat) {
        let hl = Highlightr()
        // "atom-one-dark" sits well on `Theme.consoleBG`.
        hl?.setTheme(to: "atom-one-dark")
        hl?.theme.setCodeFont(.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        highlightr = hl
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        guard let highlightr,
              let highlighted = highlightr.highlight(content, as: language, fastRender: true)
        else {
            return Text(content)
        }
        return Text(AttributedString(highlighted))
    }
}

extension CodeSyntaxHighlighter where Self == ModeloSyntaxHighlighter {
    static var modelo: ModeloSyntaxHighlighter { .shared }
}
