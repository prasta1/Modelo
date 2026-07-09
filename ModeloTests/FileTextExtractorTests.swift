import Testing
import Foundation
@testable import Modelo

@Suite("FileTextExtractor")
struct FileTextExtractorTests {

    // MARK: Text extraction

    @Test("extracts UTF-8 text from a temp file")
    func extractsPlainText() throws {
        let content = "Hello, world!\nLine two."
        let url = try writeTempFile(name: "test.txt", content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = FileTextExtractor.extract(url: url)
        #expect(result == content)
    }

    @Test("returns nil for an unreadable path")
    func returnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/does_not_exist_modelo.txt")
        #expect(FileTextExtractor.extract(url: url) == nil)
    }

    // MARK: Truncation

    @Test("truncates text beyond maxCharacters")
    func truncatesLongText() throws {
        let long = String(repeating: "a", count: FileTextExtractor.maxCharacters + 100)
        let url = try writeTempFile(name: "big.txt", content: long)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try #require(FileTextExtractor.extract(url: url))
        #expect(result.contains("[… truncated"))
        // Verify the prefix is exactly maxCharacters of 'a' before the truncation banner.
        let prefix = String(result.prefix(FileTextExtractor.maxCharacters))
        #expect(prefix == String(repeating: "a", count: FileTextExtractor.maxCharacters))
    }

    @Test("does not truncate text within maxCharacters")
    func doesNotTruncateShortText() throws {
        let short = String(repeating: "b", count: 100)
        let url = try writeTempFile(name: "small.txt", content: short)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = FileTextExtractor.extract(url: url)
        #expect(result == short)
    }

    // MARK: Jupyter notebook extraction

    @Test("extracts code and markdown cells from .ipynb")
    func extractsNotebook() throws {
        let notebook = """
        {
          "cells": [
            {"cell_type": "markdown", "source": ["# Title\\n", "Some text."]},
            {"cell_type": "code",     "source": ["import pandas as pd\\n", "df = pd.read_csv('data.csv')"]},
            {"cell_type": "markdown", "source": [""]}
          ]
        }
        """
        let url = try writeTempFile(name: "notebook.ipynb", content: notebook)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try #require(FileTextExtractor.extract(url: url))
        #expect(result.contains("# Title"))
        #expect(result.contains("```python"))
        #expect(result.contains("import pandas as pd"))
    }

    @Test("extracts notebook cell with string source field")
    func extractsNotebookWithStringSource() throws {
        let notebook = """
        {
          "cells": [
            {"cell_type": "code", "source": "import os"}
          ]
        }
        """
        let url = try writeTempFile(name: "string-source.ipynb", content: notebook)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try #require(FileTextExtractor.extract(url: url))
        #expect(result.contains("import os"))
        #expect(result.contains("```python"))
    }

    @Test("returns nil for malformed .ipynb")
    func returnsNilForBadNotebook() throws {
        let url = try writeTempFile(name: "bad.ipynb", content: "not json at all {{{")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileTextExtractor.extract(url: url) == nil)
    }

    // MARK: Helpers

    private func writeTempFile(name: String, content: String) throws -> URL {
        let unique = "\(UUID().uuidString)-\(name)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
