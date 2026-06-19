import Foundation

/// A callable tool the model can invoke. Shape mirrors MCP's tool model
/// (name + description + JSON-Schema input + string result), so a future MCP
/// client (issue #1) can register external tools through the same protocol.
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    /// `argumentsJSON` is the raw JSON the model produced for the call.
    /// Returns content for the model (markdown/text). Throwing is caught by the registry.
    func execute(argumentsJSON: String) async throws -> String
}

/// Minimal JSON-Schema object description — enough for the built-in tools.
struct JSONSchema: Encodable, Sendable {
    let type: String
    let properties: [String: Property]
    let required: [String]

    init(properties: [String: Property], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }

    struct Property: Encodable, Sendable {
        let type: String
        let description: String?
        init(_ type: String, _ description: String? = nil) {
            self.type = type
            self.description = description
        }
    }
}

/// OpenAI-format `tools[]` entry, built from a `Tool`.
struct ToolSpec: Encodable {
    let type: String
    let function: Function

    init(_ tool: any Tool) {
        self.type = "function"
        self.function = Function(name: tool.name, description: tool.description,
                                 parameters: tool.parameters)
    }

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}
