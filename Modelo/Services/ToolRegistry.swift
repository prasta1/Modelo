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

    func specs() -> [ToolSpec] { tools.values.map(ToolSpec.init) }

    func execute(name: String, argumentsJSON: String) async -> String {
        guard let tool = tools[name] else { return "Error: unknown tool \"\(name)\"." }
        do { return try await tool.execute(argumentsJSON: argumentsJSON) }
        catch { return "Error: \(error.localizedDescription)" }
    }
}
