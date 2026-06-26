import Foundation

/// A skill discovered under `~/.agents/skills/<name>/SKILL.md` (§3.7) — the portable,
/// cross-tool convention. `instructions` is the markdown body the model follows once
/// the skill is invoked.
struct AgentSkill: Sendable, Equatable {
    let name: String
    let description: String
    let instructions: String
}

/// Discovers agent skills from the shared `~/.agents` directory so Modelo can use the
/// same skills as other tools on the machine (Claude Code, etc.).
enum AgentsLoader {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agents")
    }

    /// Loads every `skills/<name>/SKILL.md` under `root`, parsing the YAML frontmatter
    /// for `name`/`description`. Missing/garbled skills are skipped. Sorted by name.
    static func loadSkills(root: URL = AgentsLoader.defaultRoot) -> [AgentSkill] {
        let dir = root.appending(path: "skills")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var skills: [AgentSkill] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let file = entry.appending(path: "SKILL.md")
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (frontmatter, body) = splitFrontmatter(content)
            let parsed = parseFrontmatter(frontmatter)
            skills.append(AgentSkill(
                name: parsed.name ?? entry.lastPathComponent,
                description: parsed.description ?? "",
                instructions: body.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// Splits a `---`-delimited YAML frontmatter block from the markdown body.
    static func splitFrontmatter(_ content: String) -> (frontmatter: String, body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ("", content) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ("", content)
        }
        let fm = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fm, body)
    }

    /// Pulls `name` and `description` (incl. folded `>`/`|` multi-line) from frontmatter.
    static func parseFrontmatter(_ frontmatter: String) -> (name: String?, description: String?) {
        let lines = frontmatter.components(separatedBy: "\n")
        var name: String?
        var description: String?
        var i = 0
        func unquote(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        while i < lines.count {
            let line = lines[i]
            if let r = line.range(of: #"^name:\s*"#, options: .regularExpression) {
                name = unquote(String(line[r.upperBound...]))
            } else if let r = line.range(of: #"^description:\s*"#, options: .regularExpression) {
                let head = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if head.isEmpty || head.first == ">" || head.first == "|" {   // also handles >-, |-, >+ etc.
                    // Folded/literal block: gather the indented continuation lines.
                    var parts: [String] = []
                    var j = i + 1
                    while j < lines.count {
                        let l = lines[j]
                        if l.range(of: #"^\s+\S"#, options: .regularExpression) != nil {
                            parts.append(l.trimmingCharacters(in: .whitespaces))
                            j += 1
                        } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                            j += 1
                        } else {
                            break
                        }
                    }
                    description = parts.joined(separator: " ")
                    i = j
                    continue
                } else {
                    description = unquote(head)
                }
            }
            i += 1
        }
        return (name, description)
    }
}

/// Lets a tool-capable model load and follow an `~/.agents` skill (§3.7). The model
/// sees the available skills in this tool's description and calls `use_skill(name)`
/// to pull a skill's full instructions into context.
struct UseSkillTool: Tool {
    let skills: [AgentSkill]
    let name = "use_skill"

    var description: String {
        let list = skills.map { "- \($0.name): \(Self.brief($0.description))" }.joined(separator: "\n")
        return """
        Load a skill's full instructions, then follow them to complete the user's task. \
        Call this when the request matches one of these available skills:
        \(list)
        """
    }

    var parameters: JSONSchema {
        JSONSchema(properties: ["name": .init("string", "The exact skill name to load.")],
                   required: ["name"])
    }

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let name: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let skill = skills.first(where: { $0.name.caseInsensitiveCompare(args.name) == .orderedSame }) else {
            return "No skill named \"\(args.name)\". Available: \(skills.map(\.name).joined(separator: ", "))."
        }
        return skill.instructions.isEmpty
            ? "The \"\(skill.name)\" skill has no instructions."
            : skill.instructions
    }

    /// First sentence (or ~140 chars) of a description, to keep the tool spec compact.
    static func brief(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if let dot = oneLine.firstIndex(of: ".") {
            let s = String(oneLine[...dot])
            if s.count <= 180 { return s }
        }
        return oneLine.count <= 140 ? oneLine : String(oneLine.prefix(140)) + "…"
    }
}
