import Foundation

/// Holds the active tools, emits their OpenAI specs for the request, and
/// dispatches a model's tool call by name. An unknown name or a thrown error
/// becomes an error *string* returned to the model — the chat loop must never
/// crash on a tool failure.
struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    init(_ tools: [any Tool]) {
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var isEmpty: Bool { tools.isEmpty }
    var count: Int { tools.count }

    func specs() -> [ToolSpec] { tools.values.map(ToolSpec.init) }

    /// (name, description) for every tool — the catalog `find_tools` searches.
    func catalog() -> [(name: String, description: String)] {
        tools.values.map { (name: $0.name, description: $0.description) }
    }

    /// Specs for just the named tools (progressive disclosure sends a relevant subset).
    func specs(named names: Set<String>) -> [ToolSpec] {
        tools.values.filter { names.contains($0.name) }.map(ToolSpec.init)
    }

    /// The approval preview for a mutating tool call, or nil if the tool runs without
    /// confirmation (read-only) or is unknown.
    func approvalPreview(name: String, argumentsJSON: String) -> ToolApprovalPreview? {
        tools[name]?.approvalPreview(argumentsJSON: argumentsJSON)
    }

    func execute(name: String, argumentsJSON: String) async -> String {
        guard let tool = tools[name] else { return "Error: unknown tool \"\(name)\"." }
        do { return try await tool.execute(argumentsJSON: argumentsJSON) }
        catch { return "Error: \(error.localizedDescription)" }
    }
}
