import Foundation

/// A chat slash command (§3.1). Parsed from the composer before a message is sent.
enum SlashCommand: Equatable {
    case help
    case clear
    case copy
    case skills                // list available ~/.agents skills (§3.7)
    case temperature(Double)
    case system(String)        // empty string clears the per-conversation prompt
    case model(String)         // a query to match against discovered models
}

/// Parses composer input into a `SlashCommand`. Returns nil for ordinary text (and
/// for an unrecognized `/word`, so the user can still send literal slash text).
enum SlashParser {
    static func parse(_ input: String) -> SlashCommand? {
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
        case "temp", "temperature":
            guard let t = Double(arg) else { return nil }   // "/temp" w/o a number → send as text
            return .temperature(t)
        case "system", "sys":
            return .system(arg)
        case "model", "m":
            guard !arg.isEmpty else { return nil }
            return .model(arg)
        default:
            return nil
        }
    }

    /// One-line help shown by `/help`.
    static let helpText = """
    Commands: /model <name> · /temp <0–2> · /system <prompt> · /skills · /clear · /copy · /help
    """
}
