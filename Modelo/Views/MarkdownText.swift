import SwiftUI
import AppKit
import MarkdownUI
import Highlightr

// MARK: - Syntax highlighter

/// Wraps Highlightr's JS-backed engine as a MarkdownUI CodeSyntaxHighlighter.
/// One shared instance amortises the ~150ms JS cold-start across all code blocks.
final class ModeloHighlighter: CodeSyntaxHighlighter {
    static let shared = ModeloHighlighter()

    private let engine: Highlightr? = {
        guard let h = Highlightr() else { return nil }
        h.setTheme(to: "atom-one-dark")
        return h
    }()

    func highlightCode(_ content: String, language: String?) -> Text {
        guard let engine,
              let nsAttr = engine.highlight(content, as: language, fastRender: true),
              let attrStr = try? AttributedString(nsAttr, including: \.appKit) else {
            return Text(content)
        }
        return Text(attrStr)
    }
}

// MARK: - Code block container

private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Theme.line)
                .frame(height: 0.5)
            configuration.label
                .font(Theme.code(12.5))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(Theme.consoleBG, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
    }

    private var header: some View {
        HStack {
            if let lang = configuration.language {
                Text(lang.lowercased())
                    .font(Theme.code(10))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            Button(action: copyCode) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.green : Theme.textDim)
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - Modelo MarkdownUI theme

private extension MarkdownUI.Theme {
    static var modelo: Self {
        .gitHub
            .text {
                ForegroundColor(Theme.textMid)
            }
            .link {
                ForegroundColor(Theme.amber)
            }
            .code {
                FontFamilyVariant(.monospaced)
                ForegroundColor(Theme.amber)
                BackgroundColor(Theme.fill)
            }
            .codeBlock { configuration in
                CodeBlockView(configuration: configuration)
            }
    }
}

// MARK: - Public view

/// Renders assistant message content as Markdown with Modelo's dark theme
/// and Highlightr-backed syntax-highlighted code blocks.
struct MarkdownText: View {
    let content: String
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15

    var body: some View {
        Markdown(content)
            .markdownTheme(.modelo)
            .markdownCodeSyntaxHighlighter(ModeloHighlighter.shared)
            .markdownTextStyle {
                FontSize(messageFontSize)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
