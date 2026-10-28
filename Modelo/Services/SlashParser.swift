import Foundation

/// A chat slash command (§3.1). Parsed from the composer before a message is sent.
enum SlashCommand: Equatable {
    case help
    case clear
    case copy
    case export                // write the conversation to ~/Downloads as Markdown (§3.2)
    case skills                // open the pickable skills list (§3.7)
    case skill(name: String, text: String)   // run a skill with optional request text (§3.7)
    case compact               // summarize older turns now to free context (§1.5)
    case temperature(Double)
    case system(String)        // empty string clears the per-conversation prompt
    case model(String)         // a query to match against discovered models
}

/// Parses composer input into a `SlashCommand`. Returns nil for ordinary text (and
/// for an unrecognized `/word`, so the user can still send literal slash text).
enum SlashParser {
    /// `skillNames` are the enabled skills; a `/word` matching one (case-insensitively)
    /// becomes `.skill`. Built-in commands are checked first, so they win on a clash.
    static func parse(_ input: String, skillNames: [String] = []) -> SlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        // Split the leading "/command" from the remainder (the argument string).
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawCmd = parts.first.map(String.init), !rawCmd.isEmpty else { return nil }
        let cmd = rawCmd.lowercased()
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch cmd {
        case "help", "?", "h":
            return .help
        case "clear", "reset":
            return .clear
        case "copy":
            return .copy
        case "skills":
            return .skills
        case "compact", "summarize":
            return .compact
        case "export", "save":
            return .export
        case "temp", "temperature":
            guard let t = Double(arg) else { return nil }   // "/temp" w/o a number → send as text
            return .temperature(t)
        case "system", "sys":
            return .system(arg)
        case "model", "m":
            guard !arg.isEmpty else { return nil }
            return .model(arg)
        default:
            guard let name = skillNames.first(where: { $0.lowercased() == cmd }) else { return nil }
            return .skill(name: name, text: arg)
        }
    }

    /// One-line help shown by `/help`.
    static let helpText = """
    Commands: /model <name> · /temp <0–2> · /system <prompt> · /skills [filter] · /<skill> [request] · /compact · /export · /clear · /copy · /help
    """

    // MARK: - Autocomplete (§3.1)

    /// A command shown in the composer's slash-autocomplete popup.
    struct Spec: Identifiable, Equatable {
        let token: String        // canonical command, e.g. "model"
        let arg: String?         // argument hint, e.g. "<name>"; nil = no argument
        let summary: String
        /// True for a skill row (shown under the built-in commands).
        var isSkill: Bool = false
        var id: String { token }
        var takesArg: Bool { arg != nil }
    }

    /// The user-facing command palette, in display order.
    static let catalog: [Spec] = [
        Spec(token: "model",  arg: "<name>",   summary: "Switch the model"),
        Spec(token: "temp",   arg: "<0–2>",    summary: "Set temperature for this chat"),
        Spec(token: "system", arg: "<prompt>", summary: "Set the system prompt (empty clears)"),
        Spec(token: "skills", arg: "[filter]", summary: "Pick from your skills"),
        Spec(token: "compact", arg: nil,       summary: "Summarize earlier turns to free up context"),
        Spec(token: "export", arg: nil,        summary: "Save the chat to ~/Downloads as Markdown"),
        Spec(token: "copy",   arg: nil,        summary: "Copy the last response"),
        Spec(token: "clear",  arg: nil,        summary: "Clear the conversation"),
        Spec(token: "help",   arg: nil,        summary: "Show available commands"),
    ]

    /// Commands and skills to suggest for the current composer text. Empty unless the
    /// input is a bare `/word` with no argument yet (a space means the user is typing an
    /// argument) — except `/skills <filter>`, which lists only skills matching the filter.
    static func suggestions(for input: String, skills: [AgentSkill] = []) -> [Spec] {
        guard input.hasPrefix("/") else { return [] }
        // Skills named like a built-in can never run (`parse` matches the built-in first),
        // so they're never offered.
        let runnable = skills.filter { !reservedWords.contains($0.name.lowercased()) }
        if isSkillsListMode(input) {
            let filter = input.dropFirst("/skills ".count).lowercased()
            return runnable.filter { filter.isEmpty || $0.name.lowercased().contains(filter) }.map(spec(for:))
        }
        let body = input.dropFirst()
        guard !body.contains(" ") else { return [] }     // typing an argument → stop suggesting
        let typed = body.lowercased()
        let builtIns = catalog.filter { typed.isEmpty || $0.token.hasPrefix(typed) }
        let matching = runnable.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }
        return builtIns + matching.map(spec(for:))
    }

    /// Every word `parse` treats as a built-in command, aliases included. Keep in sync
    /// with the switch in `parse`.
    static let reservedWords: Set<String> = [
        "help", "?", "h", "clear", "reset", "copy", "skills", "compact", "summarize",
        "export", "save", "temp", "temperature", "system", "sys", "model", "m",
    ]

    /// True once the draft is `/skills ` (with the space): the popup shows the skill list.
    static func isSkillsListMode(_ input: String) -> Bool {
        input.lowercased().hasPrefix("/skills ")
    }

    private static func spec(for skill: AgentSkill) -> Spec {
        Spec(token: skill.name, arg: "[request]", summary: UseSkillTool.brief(skill.description), isSkill: true)
    }
}
