import SwiftUI
import AppKit
import MarkdownUI

/// Identifies an expanded table window. `WindowGroup(for:)` keys windows on this
/// value, so expanding the same table twice focuses the window already showing it
/// instead of opening a duplicate.
struct TablePayload: Codable, Hashable {
    /// The table's Markdown source, re-rendered in the window.
    let markdown: String

    /// Column count, read off the header row. Used to pick an opening width and
    /// to label the window.
    var columnCount: Int {
        guard let header = markdown.split(separator: "\n").first else { return 0 }
        return header.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .split(separator: "|", omittingEmptySubsequences: false)
            .count
    }

    /// Data row count, excluding the header and the `| --- |` alignment row.
    var rowCount: Int {
        max(0, MarkdownTable.dataRows(in: markdown).count - 1)
    }

    /// A width that fits most tables without wrapping, clamped to the screen so a
    /// wide table can't open off-display. An exact fit isn't achievable — the
    /// underlying grid has no measurable natural width — so this opens roomy and
    /// leaves the rest to the resize handles.
    var preferredWidth: CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1400
        return min(screen * 0.9, max(700, CGFloat(columnCount) * 260))
    }
}

/// The expanded view of a Markdown table: the same table rendering as in chat,
/// given a whole resizable window so cells wrap far less.
struct TableWindowView: View {
    let payload: TablePayload
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView(.vertical) {
                MarkdownText(content: payload.markdown, fontSize: messageFontSize)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(Theme.windowBG)
        .modeloWindowChrome(center: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(payload.columnCount) × \(payload.rowCount)")
                .font(Theme.code(10))
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
            Button("Copy as TSV", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                .labelStyle(.titleAndIcon)
                .font(Theme.code(10))
                .foregroundStyle(copied ? Theme.green : Theme.textDim)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.fillHi)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownTable.tsv(from: payload.markdown), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// Markdown table source → spreadsheet-friendly text. Shared by the inline table's
/// copy button and the expanded window's.
enum MarkdownTable {
    /// The source's rows with blank lines and the `| --- | :--: |` alignment row
    /// dropped, since the latter carries no data.
    static func dataRows(in markdown: String) -> [String] {
        markdown
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(where: { !"|-: ".contains($0) }) }
    }

    /// The table as tab-separated rows, so pasting lands as real cells in
    /// Numbers/Excel rather than as a wall of pipe characters.
    static func tsv(from markdown: String) -> String {
        dataRows(in: markdown)
            .map { row in
                row.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\t")
            }
            .joined(separator: "\n")
    }
}
