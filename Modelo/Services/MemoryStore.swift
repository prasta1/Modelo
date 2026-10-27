import Foundation
import CryptoKit

/// One persisted memory entry — a markdown file with `---` frontmatter under
/// `~/.modelo/memory/<scope>/<name>.md`. Memories are durable facts saved across
/// conversations (user preferences, project knowledge), created by the model via
/// `save_memory` or by hand in Settings ▸ Memory.
struct Memory: Sendable, Equatable, Identifiable {
    var id: String { name }
    /// Slug identity within its scope. The filename stem is authoritative — a
    /// hand-renamed file keeps working even if its frontmatter `name` disagrees.
    let name: String
    /// One line shown in the injected memory index.
    let description: String
    /// Full markdown content returned by `read_memory`.
    let body: String
    let updatedAt: Date?
    let fileURL: URL
}

/// Where a memory lives: shared across all chats, or keyed to a project directory.
enum MemoryScope: Sendable, Equatable {
    case global
    case project(path: String)   // absolute project directory path
}

/// Errors from the memory store, phrased so a (possibly weak) model gets an
/// actionable message it can correct from on the next round.
enum MemoryError: LocalizedError {
    case emptyName
    case emptyBody
    case bodyTooLarge(Int)
    case writeFailed(String)
    case badArguments(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:           "Provide a short name for the memory (e.g. \"preferred-code-style\")."
        case .emptyBody:           "Provide the memory content — the fact or preference to remember."
        case .bodyTooLarge(let n): "Memory content is too large (\(n) bytes, limit \(MemoryStore.maxBodyBytes)). Memories are short facts, not documents — save a condensed version."
        case .writeFailed(let why): "Could not save the memory: \(why)"
        case .badArguments(let why): "Invalid arguments: \(why)"
        }
    }
}

/// Stateless file-backed store for memories under `~/.modelo/memory`. All functions
/// take an injectable `root` for tests (mirrors `AgentsLoader.loadSkills(root:)`).
/// Writes are atomic, so concurrent chats race benignly (last writer wins). The
/// index is always computed from the files on disk — hand edits can never drift.
enum MemoryStore {
    /// `@AppStorage` key for the master switch (off by default — one-off chats stay one-off).
    static let enabledKey = "memoryEnabled"
    /// `@AppStorage` key: whether cloud endpoints see memories (off by default). Off,
    /// cloud turns get neither the index nor the memory tools; on, each `read_memory`
    /// on a cloud turn asks first. Local endpoints are unaffected either way.
    static let shareWithCloudKey = "memoryShareWithCloud"

    /// Cap on a single memory body: ~2k tokens, so one `read_memory` can't blow a
    /// small local-model context.
    static let maxBodyBytes = 8 * 1024

    /// Skip anything bigger than this when listing (a hand-dropped file that clearly
    /// isn't a memory).
    static let maxFileBytes = 256 * 1024

    /// Most index lines per scope; the rest collapse into a "… (N more)" line.
    static let maxIndexEntries = 30

    static var defaultRoot: URL {
        FSToolSettings.defaultRoot.appending(path: "memory")
    }

    // MARK: Directories & slugs

    static func directory(for scope: MemoryScope, root: URL = defaultRoot) -> URL {
        switch scope {
        case .global:             root.appending(path: "global")
        case .project(let path):  root.appending(path: projectSlug(forPath: path))
        }
    }

    /// Deterministic directory name for a project path: sanitized folder name plus
    /// a short path hash — `Modelo-3fa9c2d1`. The hash suffix means two same-named
    /// folders can't collide, and nothing can collide with the literal `global`.
    static func projectSlug(forPath path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        let hash8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(nameSlug(URL(fileURLWithPath: standardized).lastPathComponent))-\(hash8)"
    }

    /// Normalizes a memory name to a filesystem-safe slug: lowercased, whitespace
    /// becomes `-`, everything outside `[a-z0-9-_]` is dropped. Because `/` and `.`
    /// cannot survive, a model-supplied name can never escape the scope directory —
    /// this is why `save_memory` needs no approval card.
    static func nameSlug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isWhitespace { out.append("-") }
            else if ch == "-" || ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber)) { out.append(ch) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.count > 64 { out = String(out.prefix(64)) }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "memory" : out
    }

    // MARK: CRUD

    /// All memories in a scope, sorted by name. Tolerant of hand-edited or corrupt
    /// files: non-`.md`, oversized, or non-UTF-8 entries are skipped, and a file
    /// with no/garbled frontmatter still loads (body-only, name from the filename).
    /// A missing directory is simply an empty scope — nothing is created on read.
    static func list(_ scope: MemoryScope, root: URL = defaultRoot) -> [Memory] {
        let dir = directory(for: scope, root: root)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var memories: [Memory] = []
        for file in entries where file.pathExtension.lowercased() == "md" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxFileBytes else { continue }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            memories.append(parse(content, fileURL: file))
        }
        return memories.sorted { $0.name < $1.name }
    }

    static func read(name: String, scope: MemoryScope, root: URL = defaultRoot) -> Memory? {
        let dir = directory(for: scope, root: root)
        for stem in lookupStems(name) {
            let file = dir.appending(path: "\(stem).md")
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                return parse(content, fileURL: file)
            }
        }
        return nil
    }

    /// Candidate filename stems for a name lookup: the slug first (tool-saved files),
    /// then the raw name so hand-renamed files — listed in the index under their raw
    /// stem — stay readable and deletable. The raw form is only tried when it cannot
    /// traverse out of the scope directory.
    private static func lookupStems(_ name: String) -> [String] {
        let slug = nameSlug(name)
        guard name != slug, !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else {
            return [slug]
        }
        return [slug, name]
    }

    /// Creates or overwrites the memory named `name` (same slug = update in place).
    /// The scope directory is created lazily here — never on read.
    @discardableResult
    static func save(name: String, description: String, body: String,
                     scope: MemoryScope, root: URL = defaultRoot,
                     now: Date = Date()) throws -> Memory {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.emptyName }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { throw MemoryError.emptyBody }
        guard trimmedBody.utf8.count <= maxBodyBytes else { throw MemoryError.bodyTooLarge(trimmedBody.utf8.count) }

        let slug = nameSlug(name)
        let dir = directory(for: scope, root: root)
        let file = dir.appending(path: "\(slug).md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try serialize(name: slug, description: description, body: trimmedBody, updated: now)
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw MemoryError.writeFailed(error.localizedDescription)
        }
        return Memory(name: slug, description: oneLine(description, max: 500),
                      body: trimmedBody, updatedAt: now, fileURL: file)
    }

    /// Removes the memory if it exists; deleting a missing memory is a no-op.
    static func delete(name: String, scope: MemoryScope, root: URL = defaultRoot) throws {
        let dir = directory(for: scope, root: root)
        for stem in lookupStems(name) {
            let file = dir.appending(path: "\(stem).md")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
                return
            }
        }
    }

    // MARK: Format (pure, directly testable)

    static func serialize(name: String, description: String, body: String, updated: Date) -> String {
        // A leading `>` or `|` would read back as a YAML block scalar (empty value) —
        // quote it so the description survives the round trip.
        let desc = oneLine(description, max: 500)
        let safeDesc = (desc.hasPrefix(">") || desc.hasPrefix("|")) ? "\"\(desc)\"" : desc
        return """
        ---
        name: \(nameSlug(name))
        description: \(safeDesc)
        updated: \(iso8601.string(from: updated))
        ---
        \(body)
        """
    }

    /// Parses file contents into a `Memory`. Never fails: missing frontmatter means
    /// the whole file is the body, the filename stem is the name, and the first
    /// non-empty body line stands in for a missing description.
    static func parse(_ contents: String, fileURL: URL) -> Memory {
        let (frontmatter, body) = AgentsLoader.splitFrontmatter(contents)
        let parsed = AgentsLoader.parseFrontmatter(frontmatter)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedAt: Date?
        for line in frontmatter.components(separatedBy: "\n") {
            if let r = line.range(of: #"^updated:\s*"#, options: .regularExpression) {
                updatedAt = iso8601.date(from: String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        let fallback = trimmedBody.components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let description = (parsed.description?.isEmpty == false) ? parsed.description! : fallback
        // Clip to the serialize cap, not tighter — the editor writes this value back,
        // so a load-time clip would silently truncate the stored description.
        return Memory(name: fileURL.deletingPathExtension().lastPathComponent,
                      description: oneLine(description, max: 500),
                      body: trimmedBody,
                      updatedAt: updatedAt,
                      fileURL: fileURL)
    }

    // MARK: Index injection

    /// The compact memory index appended to the system prompt — one line per memory,
    /// full bodies only on demand via `read_memory` (small local contexts). Nil when
    /// every scope is empty so an unused feature costs zero tokens. Pass
    /// `toolsAvailable: false` when the memory tools aren't offered this request
    /// (model without tool support, tools toggled off) so the text stays purely
    /// informational instead of commanding calls the model can't make.
    static func indexInjection(scopes: [MemoryScope], toolsAvailable: Bool = true,
                               root: URL = defaultRoot) -> String? {
        var lines: [String] = []
        for scope in scopes {
            let tag = switch scope { case .global: "global"; case .project: "project" }
            let memories = list(scope, root: root)
            for memory in memories.prefix(maxIndexEntries) {
                lines.append("- [\(tag)] \(memory.name) — \(oneLine(memory.description, max: 100))")
            }
            if memories.count > maxIndexEntries {
                lines.append(toolsAvailable
                    ? "- … (\(memories.count - maxIndexEntries) more \(tag) memories; use read_memory or ask)"
                    : "- … (\(memories.count - maxIndexEntries) more \(tag) memories)")
            }
        }
        guard !lines.isEmpty else { return nil }
        let preamble = toolsAvailable
            ? """
              Saved memories from past conversations (name — description). When one looks \
              relevant, call read_memory with its name before answering. Save new lasting \
              facts, preferences, or corrections with save_memory.
              """
            : "Saved memories from past conversations (name — description), for context."
        return "## Memory\n\(preamble)\n\(lines.joined(separator: "\n"))"
    }

    // MARK: Helpers

    private static let iso8601 = ISO8601DateFormatter()

    /// Collapses text to a single clipped line for frontmatter and index use.
    private static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}
