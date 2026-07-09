import Foundation
import PDFKit

/// Extracts plain text from files for inline attachment in chat messages.
/// Supports plain text, source code, PDF, and Jupyter notebooks.
/// Content is truncated at `maxCharacters` to avoid blowing the model's context.
enum FileTextExtractor {

    static let maxCharacters = 50_000

    /// Returns extracted text for the file at `url`, or nil if extraction fails.
    static func extract(url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":   return extractPDF(url: url)
        case "ipynb": return extractNotebook(url: url)
        default:      return extractText(url: url)
        }
    }

    // MARK: - Private

    private static func extractText(url: URL) -> String? {
        // Try UTF-8 first, fall back to Latin-1 for legacy files.
        let raw = (try? String(contentsOf: url, encoding: .utf8))
               ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        return raw.map(truncate)
    }

    private static func extractPDF(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string, !text.isEmpty {
                pages.append(text)
            }
        }
        let joined = pages.joined(separator: "\n\n")
        return joined.isEmpty ? nil : truncate(joined)
    }

    /// Parses a Jupyter notebook and returns its cell sources as markdown.
    /// Code cells become fenced ```python blocks; markdown cells are kept as-is.
    private static func extractNotebook(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = json["cells"] as? [[String: Any]]
        else { return nil }

        let parts: [String] = cells.compactMap { cell in
            guard let cellType = cell["cell_type"] as? String else { return nil }
            let content: String
            if let lines = cell["source"] as? [String] {
                content = lines.joined()
            } else if let str = cell["source"] as? String {
                content = str
            } else {
                return nil
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // TODO: read metadata.kernelspec.language for non-Python kernels.
            return cellType == "code" ? "```python\n\(trimmed)\n```" : trimmed
        }

        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : truncate(joined)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
            + "\n\n[… truncated — file exceeds \(maxCharacters / 1_000)K characters]"
    }
}
