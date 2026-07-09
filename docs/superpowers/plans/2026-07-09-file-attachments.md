# File Attachments (Non-Image) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to attach text-based files (code, CSV, JSON, PDF, Jupyter notebooks, configs, logs, etc.) to any chat message regardless of whether the selected model supports vision, with file content inlined as labeled text blocks in the wire request.

**Architecture:** Text attachments reuse the existing `MessageAttachment` struct (no SwiftData migration). A new `isImage` computed property on `MessageAttachment` discriminates between image and text attachments. At wire-serialization time in `LMStudioClient`, text attachments are formatted as `<file name="…">…</file>` text blocks and prepended before the user's typed message. A new paperclip button (always visible, no vision gate) sits in the composer alongside the existing image button. PDF extraction uses PDFKit (built-in macOS framework); `.ipynb` cells are parsed from the notebook's JSON structure.

**Tech Stack:** Swift, SwiftUI, AppKit (NSOpenPanel), PDFKit, Foundation (JSONSerialization for .ipynb), Swift Testing framework

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Modify | `Modelo/Modelo/Models/Message.swift` | Add `isImage` to `MessageAttachment` |
| Create | `Modelo/Modelo/Services/FileTextExtractor.swift` | PDF/notebook/text extraction + truncation |
| Create | `Modelo/ModeloTests/FileTextExtractorTests.swift` | Unit tests for extractor |
| Modify | `Modelo/Modelo/Services/LMStudioClient.swift:232-239` | Wire format: inline text attachments as labeled blocks |
| Modify | `Modelo/Modelo/Views/ChatView.swift` | `pickFiles()`, `textMimeType(for:)`, `attachFileButton`, `fileSystemImage(for:)`, attachment strip update, composer button |

---

## Task 1: Add `isImage` to `MessageAttachment`

**Files:**
- Modify: `Modelo/Modelo/Models/Message.swift:11-28`

- [ ] **Step 1: Add `isImage` computed property**

In `Message.swift`, add the property to the `MessageAttachment` struct immediately after `var fileName: String`:

```swift
/// True for `image/*` MIME types (vision path); false for all text files (inline path).
var isImage: Bool { mimeType.hasPrefix("image/") }
```

The struct should look like:

```swift
struct MessageAttachment: Codable, Sendable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    var isImage: Bool { mimeType.hasPrefix("image/") }

    init(data: Data, mimeType: String, fileName: String) {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// Base64 data URL for OpenAI-compatible vision APIs.
    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}
```

- [ ] **Step 2: Verify no compiler errors**

Use Xcode's `XcodeRefreshCodeIssuesInFile` on `Message.swift`. Expect: no issues.

- [ ] **Step 3: Commit**

```bash
git add Modelo/Modelo/Models/Message.swift
git commit -m "feat: add isImage discriminator to MessageAttachment"
```

---

## Task 2: Create `FileTextExtractor` service

**Files:**
- Create: `Modelo/Modelo/Services/FileTextExtractor.swift`

- [ ] **Step 1: Create the file**

```swift
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
            guard let cellType = cell["cell_type"] as? String,
                  let source = cell["source"] as? [String]
            else { return nil }
            let content = source.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return cellType == "code" ? "```python\n\(content)\n```" : content
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
```

- [ ] **Step 2: Verify no compiler errors**

Use Xcode's `XcodeRefreshCodeIssuesInFile` on `FileTextExtractor.swift`. Expect: no issues.

---

## Task 3: Unit tests for `FileTextExtractor`

**Files:**
- Create: `Modelo/ModeloTests/FileTextExtractorTests.swift`

- [ ] **Step 1: Create the test file**

```swift
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
        #expect(result.count < long.count)
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

    @Test("returns nil for malformed .ipynb")
    func returnsNilForBadNotebook() throws {
        let url = try writeTempFile(name: "bad.ipynb", content: "not json at all {{{")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileTextExtractor.extract(url: url) == nil)
    }

    // MARK: Helpers

    private func writeTempFile(name: String, content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

- [ ] **Step 2: Run the tests**

Use Xcode's run tests on `FileTextExtractorTests`. Expected: all 5 pass.

- [ ] **Step 3: Commit**

```bash
git add Modelo/Modelo/Services/FileTextExtractor.swift \
        Modelo/ModeloTests/FileTextExtractorTests.swift
git commit -m "feat: add FileTextExtractor for text/PDF/notebook attachments"
```

---

## Task 4: Wire format — inline text attachments as labeled blocks

**Files:**
- Modify: `Modelo/Modelo/Services/LMStudioClient.swift:232-239`

The current block (lines 232–239) only handles image attachments. Replace it to also handle text attachments.

- [ ] **Step 1: Replace the user-message serialization block**

Find this existing code (around line 232):

```swift
case .user:
    let imageAtts = m.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
    if imageAtts.isEmpty {
        if !m.content.isEmpty { wire.append(WireMessage(role: "user", content: m.content)) }
    } else {
        var blocks: [WireContentBlock] = []
        if !m.content.isEmpty { blocks.append(.text(m.content)) }
        for att in imageAtts { blocks.append(.imageURL(att.dataURL)) }
        wire.append(WireMessage(role: "user", blocks: blocks))
    }
```

Replace it with:

```swift
case .user:
    let allAtts = m.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
    let imageAtts = allAtts.filter { $0.isImage }
    let textAtts  = allAtts.filter { !$0.isImage }

    if allAtts.isEmpty {
        if !m.content.isEmpty { wire.append(WireMessage(role: "user", content: m.content)) }
    } else {
        var blocks: [WireContentBlock] = []
        // Text file attachments come first, each as a labeled fenced block.
        for att in textAtts {
            let text = String(data: att.data, encoding: .utf8) ?? ""
            blocks.append(.text("<file name=\"\(att.fileName)\">\n\(text)\n</file>"))
        }
        // User's typed message (may be empty if they attached without typing).
        if !m.content.isEmpty { blocks.append(.text(m.content)) }
        // Image attachments last (vision models only).
        for att in imageAtts { blocks.append(.imageURL(att.dataURL)) }
        wire.append(WireMessage(role: "user", blocks: blocks))
    }
```

- [ ] **Step 2: Verify no compiler errors**

Use `XcodeRefreshCodeIssuesInFile` on `LMStudioClient.swift`. Expect: no issues.

- [ ] **Step 3: Commit**

```bash
git add Modelo/Modelo/Services/LMStudioClient.swift
git commit -m "feat: inline text file attachments as labeled blocks in wire messages"
```

---

## Task 5: ChatView — file picker, MIME types, and file attach button

**Files:**
- Modify: `Modelo/Modelo/Views/ChatView.swift`

Three additions: the `pickFiles()` action, `textMimeType(for:)` helper, and the `attachFileButton` view — then wire the button into the composer.

- [ ] **Step 1: Add `pickFiles()` and `textMimeType(for:)` after `pickImages()` (around line 1107)**

```swift
private func pickFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowsOtherFileTypes = true
    panel.allowedContentTypes = []
    panel.title = "Attach a file"
    panel.message = "Text, code, PDF, CSV, JSON, notebooks…"
    guard panel.runModal() == .OK else { return }

    let binaryExtensions: Set<String> = [
        "parquet", "pkl", "arrow", "xlsx", "docx", "pptx",
        "zip", "gz", "tar", "bin", "exe", "dmg", "mp4", "mov"
    ]

    for url in panel.urls {
        let ext = url.pathExtension.lowercased()
        if binaryExtensions.contains(ext) {
            flash(".\(ext) files cannot be attached — binary format not supported.")
            continue
        }
        guard let content = FileTextExtractor.extract(url: url) else {
            flash("Could not read \(url.lastPathComponent).")
            continue
        }
        pendingAttachments.append(MessageAttachment(
            data: Data(content.utf8),
            mimeType: textMimeType(for: url),
            fileName: url.lastPathComponent
        ))
    }
}

private func textMimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "pdf":                               return "application/pdf"
    case "json", "jsonl", "ipynb":            return "application/json"
    case "csv", "tsv":                        return "text/csv"
    case "yaml", "yml":                       return "application/yaml"
    case "xml":                               return "application/xml"
    case "md", "rst":                         return "text/markdown"
    case "html":                              return "text/html"
    case "py":                                return "text/x-python"
    case "js", "ts", "jsx", "tsx":           return "text/javascript"
    case "swift":                             return "text/x-swift"
    case "go":                                return "text/x-go"
    case "rs":                                return "text/x-rust"
    case "java", "kt":                        return "text/x-java"
    case "c", "cpp", "cc", "cxx", "h", "hpp": return "text/x-c"
    case "rb":                                return "text/x-ruby"
    case "cs":                                return "text/x-csharp"
    case "php":                               return "text/x-php"
    case "sql":                               return "application/sql"
    case "sh", "bash", "zsh":               return "application/x-sh"
    default:                                  return "text/plain"
    }
}
```

- [ ] **Step 2: Add `attachFileButton` view after `attachButton` (around line 1089)**

```swift
private var attachFileButton: some View {
    Button(action: pickFiles) {
        Image(systemName: "paperclip")
            .font(.system(size: 16))
            .foregroundStyle(Theme.Palette.inkDim)
            .frame(width: 36, height: 36)
    }
    .buttonStyle(.plain)
    .help("Attach a file — text, code, PDF, CSV, JSON, notebooks…")
}
```

- [ ] **Step 3: Add `attachFileButton` to the composer HStack**

Find this block in the `composer` view (around line 980):

```swift
HStack(alignment: .bottom, spacing: 10) {
    if pickedModel?.model.supportsVision == true {
        attachButton
    }
    ComposerField(
```

Replace with:

```swift
HStack(alignment: .bottom, spacing: 10) {
    attachFileButton
    if pickedModel?.model.supportsVision == true {
        attachButton
    }
    ComposerField(
```

- [ ] **Step 4: Verify no compiler errors**

Use `XcodeRefreshCodeIssuesInFile` on `ChatView.swift`. Expect: no issues.

- [ ] **Step 5: Commit**

```bash
git add Modelo/Modelo/Views/ChatView.swift
git commit -m "feat: add file attach button and picker to chat composer"
```

---

## Task 6: Attachment strip — file chips for text attachments

**Files:**
- Modify: `Modelo/Modelo/Views/ChatView.swift`

The strip currently renders image thumbnails unconditionally. Branch on `att.isImage` so text attachments show as labeled chips instead.

- [ ] **Step 1: Add `fileSystemImage(for:)` helper**

Add this function in the `// MARK: Image picking and drop handling` section:

```swift
/// Maps a file extension to an SF Symbol name for the attachment chip icon.
private func fileSystemImage(for fileName: String) -> String {
    let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    switch ext {
    case "pdf":                                              return "doc.richtext"
    case "csv", "tsv":                                       return "tablecells"
    case "json", "jsonl", "ipynb":                           return "curlybraces"
    case "md", "rst", "txt":                                 return "doc.text"
    case "yaml", "yml", "toml", "env", "ini":               return "gear"
    case "sql":                                              return "cylinder"
    case "sh", "bash", "zsh":                               return "terminal"
    case "log":                                              return "list.bullet.rectangle"
    case "patch", "diff":                                    return "arrow.left.arrow.right"
    case "py", "js", "ts", "swift", "go", "rs",
         "java", "kt", "c", "cpp", "h", "rb", "cs", "php": return "chevron.left.forwardslash.chevron.right"
    default:                                                 return "doc"
    }
}
```

- [ ] **Step 2: Replace the `attachmentStrip` `ForEach` body**

Find the current `ForEach` inside `attachmentStrip` (around line 1049):

```swift
ForEach(pendingAttachments) { att in
    ZStack(alignment: .topTrailing) {
        if let img = NSImage(data: att.data) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
        }
        Button {
            pendingAttachments.removeAll { $0.id == att.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Remove attachment")
        .offset(x: 5, y: -5)
    }
}
```

Replace with:

```swift
ForEach(pendingAttachments) { att in
    ZStack(alignment: .topTrailing) {
        if att.isImage {
            if let img = NSImage(data: att.data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: fileSystemImage(for: att.fileName))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.amber)
                Text(att.fileName)
                    .font(.mono(9))
                    .foregroundStyle(Theme.textMid)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 68)
            }
            .frame(width: 72, height: 56)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.stroke, lineWidth: 0.5))
        }

        Button {
            pendingAttachments.removeAll { $0.id == att.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Remove attachment")
        .offset(x: 5, y: -5)
    }
}
```

- [ ] **Step 3: Verify no compiler errors**

Use `XcodeRefreshCodeIssuesInFile` on `ChatView.swift`. Expect: no issues.

- [ ] **Step 4: Commit**

```bash
git add Modelo/Modelo/Views/ChatView.swift
git commit -m "feat: show file chips in attachment strip for text attachments"
```

---

## Task 7: Build and smoke test

- [ ] **Step 1: Build the project**

Use `BuildProject` targeting macOS. Expect: 0 errors, 0 warnings related to our changes.

- [ ] **Step 2: Smoke test — attach a text file**

1. Run the app
2. Open any chat (model does not need to be a vision model)
3. Click the paperclip button — confirm the file picker opens
4. Attach a `.py` file — confirm a chip appears in the attachment strip with the correct icon and filename
5. Type a short message and send — verify the message is sent (no crash)

- [ ] **Step 3: Smoke test — attach a PDF**

1. Attach a PDF
2. Confirm the chip shows `doc.richtext` icon
3. Send — verify it goes through

- [ ] **Step 4: Smoke test — attach an image (regression)**

1. Select a vision model
2. Confirm the image (photo) button still appears
3. Attach an image — confirm thumbnail renders
4. Send — verify vision path still works

- [ ] **Step 5: Final commit (if any fixups needed)**

```bash
git add -p
git commit -m "fix: <description of any fixups>"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** File types (text, code, PDF, JSON, CSV, ipynb, yaml, etc.) ✓ | Picker always visible (not vision-gated) ✓ | Attachment strip shows chips ✓ | Wire format inlines content as labeled blocks ✓ | Binary files rejected with flash ✓ | Content truncated at 50K chars ✓
- [x] **No placeholders:** All code blocks are complete and runnable
- [x] **Type consistency:** `MessageAttachment.isImage` defined in Task 1, used in Tasks 4, 5, 6 — matches throughout
- [x] **No SwiftData migration needed:** `MessageAttachment` struct shape unchanged (same fields, new computed property only)
- [x] **ExoClient / MenuBarChatView:** Neither uses attachment serialization — no changes needed
