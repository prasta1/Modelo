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
            .link {
                ForegroundColor(Theme.amber)
                UnderlineStyle(.single)
            }
            .codeBlock { configuration in
                ModeloCodeBlock(configuration: configuration, fontSize: fontSize)
            }
            .table { configuration in
                ModeloTable(configuration: configuration)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                            FontSize(fontSize * 0.8)
                            ForegroundColor(Theme.textDim)
                        }
                        // Inline code inherits `fillHi`, which double-tints against
                        // the header/zebra row fills.
                        BackgroundColor(nil)
                    }
                    .textCase(configuration.row == 0 ? .uppercase : nil)
                    // Let a cell grow vertically to fit wrapped text rather than
                    // forcing every row to one line.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 11)
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
                    .hideScrollIndicators()
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

// MARK: - Tables

/// A Markdown table as a self-contained panel: tinted header row, hairline rules
/// between rows, no vertical rules, and a copy button revealed on hover.
///
/// Deliberately *not* wrapped in a horizontal `ScrollView`. A scroll view proposes
/// an unbounded width to its content, so the underlying `Grid` would size every
/// cell to one unwrapped line. Left alone, the grid inherits the message column's
/// definite width and wraps cells to fit — which is what we want for the
/// prose-heavy tables models actually emit.
private struct ModeloTable: View {
    let configuration: BlockConfiguration
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        configuration.label
            .markdownTableBorderStyle(
                TableBorderStyle(.insideHorizontalBorders, color: Theme.line, width: 1)
            )
            .markdownTableBackgroundStyle(
                .alternatingRows(Theme.fill, .clear, header: Theme.fillHi)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
            .overlay(alignment: .topTrailing) { toolbar }
            .onHover { hovering = $0 }
            .markdownMargin(top: 8, bottom: 8)
    }

    /// Expand + copy, revealed on hover. Both carry real titles rather than bare
    /// icons: `.help()` supplies a tooltip but leaves VoiceOver reading an
    /// unlabeled button, so the title stays and only the glyph is drawn.
    @ViewBuilder
    private var toolbar: some View {
        if hovering {
            HStack(spacing: 4) {
                Button("Expand table", systemImage: "arrow.up.left.and.arrow.down.right") {
                    openWindow(id: ModeloApp.tableWindowID, value: TablePayload(markdown: source))
                }
                .help("Open in a resizable window")

                Button("Copy table", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                    .foregroundStyle(copied ? Theme.green : Theme.textDim)
                    .help("Copy as TSV")
            }
            .labelStyle(.iconOnly)
            .font(Theme.code(10))
            .foregroundStyle(Theme.textDim)
            .buttonStyle(.plain)
            .padding(5)
            .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
            .padding(6)
            .transition(.opacity)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownTable.tsv(from: source), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    /// The table's own Markdown source, used both for copying and as the payload
    /// the expanded window re-renders.
    private var source: String {
        configuration.content.renderMarkdown()
    }
}

// MARK: - Syntax highlighting

/// Bridges Highlightr (highlight.js, 180+ languages) into MarkdownUI. Highlightr
/// spins up a JS context, so a single instance is shared across all code blocks.
struct ModeloSyntaxHighlighter: CodeSyntaxHighlighter {
    /// Built once. Fenced blocks render at a fixed 13pt mono, independent of the
    /// prose font, matching `Theme.code` usage elsewhere.
    static let shared = ModeloSyntaxHighlighter()

    private let highlightr: Highlightr?

    init() {
        let hl = Highlightr()
        // "atom-one-dark" sits well on `Theme.consoleBG`.
        hl?.setTheme(to: "atom-one-dark")
        hl?.theme.setCodeFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
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
