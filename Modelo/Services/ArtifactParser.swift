import Foundation

/// The kind of an artifact — drives how the panel renders it.
enum ArtifactKind: String, Sendable, Equatable {
    case code, markdown, html, svg, mermaid

    static func from(_ type: String) -> ArtifactKind {
        switch type.lowercased() {
        case "html", "text/html":          return .html
        case "svg", "image/svg+xml":       return .svg
        case "mermaid":                    return .mermaid
        case "markdown", "md", "document": return .markdown
        default:                           return .code
        }
    }

    /// Whether the panel can show a live web-rendered preview (vs. source only).
    var isRenderable: Bool { self == .html || self == .svg || self == .mermaid }

    var label: String {
        switch self {
        case .code: "Code"; case .markdown: "Document"; case .html: "HTML"
        case .svg: "SVG"; case .mermaid: "Diagram"
        }
    }
    var icon: String {
        switch self {
        case .code: "curlybraces"; case .markdown: "doc.text"; case .html: "globe"
        case .svg: "photo"; case .mermaid: "point.3.connected.trianglepath.dotted"
        }
    }
    /// File extension for the download button.
    func fileExtension(language: String?) -> String {
        switch self {
        case .html: "html"; case .svg: "svg"; case .mermaid: "mmd"; case .markdown: "md"
        case .code: (language.flatMap(Self.codeExtensions) ?? "txt")
        }
    }
    private static func codeExtensions(_ lang: String) -> String? {
        ["swift": "swift", "python": "py", "javascript": "js", "typescript": "ts",
         "rust": "rs", "go": "go", "ruby": "rb", "bash": "sh", "shell": "sh",
         "json": "json", "yaml": "yaml", "c": "c", "cpp": "cpp", "java": "java"][lang.lowercased()]
    }
}

/// A single self-contained piece of model output, rendered in the side panel rather
/// than dumped inline (§2.4). The model emits these deliberately — see `ArtifactParser`.
struct Artifact: Identifiable, Equatable, Sendable {
    let id: String          // stable identifier; reused across versions
    let title: String
    let kind: ArtifactKind
    let language: String?
    let content: String
}

/// Extracts `<artifact …>…</artifact>` blocks the model emits. Tolerant by design —
/// like the tool-call parser — so a model that fumbles the attributes still produces
/// something usable. Returns the artifacts plus the text with each block replaced by a
/// sentinel (`\u{E000}id\u{E000}`) so the chat can render a card in its place.
enum ArtifactParser {
    static let sentinel = "\u{E000}"

    static func extract(from text: String) -> (artifacts: [Artifact], cleaned: String) {
        guard text.contains("<artifact"),
              let re = try? NSRegularExpression(pattern: #"<artifact\b([^>]*)>(.*?)</artifact>"#,
                                                options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return ([], text) }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return ([], text) }

        var artifacts: [Artifact] = []
        var cleaned = ""
        var cursor = 0
        for (i, m) in matches.enumerated() {
            cleaned += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let attrs = parseAttributes(ns.substring(with: m.range(at: 1)))
            let content = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .newlines)
            let title = attrs["title"] ?? "Untitled"
            let kind = ArtifactKind.from(attrs["type"] ?? (attrs["language"] != nil ? "code" : ""))
            let id = attrs["identifier"] ?? attrs["id"] ?? slug(title, fallback: "artifact-\(i + 1)")
            artifacts.append(Artifact(id: id, title: title, kind: kind,
                                      language: attrs["language"], content: content))
            cleaned += sentinel + id + sentinel
            cursor = m.range.location + m.range.length
        }
        cleaned += ns.substring(from: cursor)
        return (artifacts, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `key="value"` pairs from an opening tag's attribute string.
    private static func parseAttributes(_ s: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#) else { return [:] }
        let ns = s as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    static func slug(_ s: String, fallback: String) -> String {
        let cleaned = s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, c in if !(acc.last == "-" && c == "-") { acc.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? fallback : cleaned
    }
}

/// All versions of one artifact id, in emission order.
struct ArtifactGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: ArtifactKind
    let language: String?
    let versions: [Artifact]
    var latest: Artifact { versions.last! }
}

/// Collects artifacts across a conversation's active path, grouping repeats of the same
/// id into ordered versions (re-emitting an id = a new version).
enum ArtifactCollector {
    static func groups(from messages: [Message]) -> [ArtifactGroup] {
        var order: [String] = []
        var byID: [String: [Artifact]] = [:]
        var meta: [String: Artifact] = [:]
        for message in messages where message.role == .assistant {
            for artifact in ArtifactParser.extract(from: message.content).artifacts {
                if byID[artifact.id] == nil { order.append(artifact.id) }
                byID[artifact.id, default: []].append(artifact)
                meta[artifact.id] = artifact   // latest metadata wins
            }
        }
        return order.compactMap { id in
            guard let versions = byID[id], let m = meta[id] else { return nil }
            return ArtifactGroup(id: id, title: m.title, kind: m.kind, language: m.language, versions: versions)
        }
    }
}

/// System-prompt scaffolding (appended when artifacts are enabled) that teaches the
/// model when and how to emit an artifact. Kept short to limit token cost.
enum ArtifactInstructions {
    static let system = """
    When you produce substantial, self-contained, reusable content — a complete HTML page, \
    an SVG image, a Mermaid diagram, a full code file, or a long document — wrap it in an \
    artifact instead of putting it inline:

    <artifact title="Short Title" type="html" identifier="stable-id">
    ...the full content...
    </artifact>

    type is one of: html, svg, mermaid, code (also add language="..."), markdown. Reuse the \
    same identifier to revise an existing artifact. Use artifacts ONLY for substantial \
    standalone content; keep short snippets, examples, and explanations inline as normal \
    Markdown. Briefly introduce each artifact in your reply.
    """
}
