import Foundation

/// Ranks tools by relevance to the user's request so a (small, easily-overwhelmed)
/// local model is shown only the few that matter, with `find_tools` to reach the rest
/// (progressive disclosure). Pure keyword overlap — no embeddings, no network.
enum ToolSelector {
    /// Names of the most relevant tools for `query`, best first, capped at `limit`.
    /// With no query (or no overlap) falls back to the first `limit` names alphabetically
    /// so the model always has a usable starting set plus `find_tools`.
    static func select(catalog: [(name: String, description: String)], query: String, limit: Int) -> [String] {
        let q = tokenize(query)
        guard !q.isEmpty else { return Array(catalog.map(\.name).sorted().prefix(limit)) }

        func score(_ entry: (name: String, description: String)) -> Int {
            let body = Set(tokenize(entry.description))
            let nameTokens = Set(tokenize(entry.name))
            var s = 0
            for t in q {
                if nameTokens.contains(t) { s += 3 }   // a name hit is a strong signal
                else if body.contains(t)  { s += 1 }
            }
            return s
        }

        return catalog
            .map { (name: $0.name, score: score($0)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .prefix(limit)
            .map(\.name)
    }

    /// Lowercased alphanumeric tokens of length ≥ 2.
    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }
}

/// Synthetic meta-tool offered in progressive-disclosure mode. Its calls are handled by
/// `ChatSession` (which reveals the matching tools for the next round), so `execute` is
/// never invoked through the registry.
struct FindToolsTool: Tool {
    static let toolName = "find_tools"
    let name = FindToolsTool.toolName
    var description: String {
        "Discover more tools by describing what you want to do. Returns tool names and descriptions you can then call directly. Use this when none of the currently listed tools fit the task — more are available than are shown."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: ["query": .init("string", "What you want to accomplish, in a few words.")],
                   required: ["query"])
    }
    func execute(argumentsJSON: String) async throws -> String {
        "find_tools is handled by the chat session."   // intercepted; not reached
    }
}
