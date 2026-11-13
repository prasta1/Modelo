import Foundation

/// A callable tool the model can invoke. Shape mirrors MCP's tool model
/// (name + description + JSON-Schema input + string result), so a future MCP
/// client (issue #1) can register external tools through the same protocol.
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    /// Whether running this tool changes state (writes a file, runs a command). Mutating
    /// tools are gated behind a user confirmation before they execute.
    var isMutating: Bool { get }
    /// A human-readable preview of what running the tool will do, shown in the
    /// confirmation card. Non-mutating tools return nil and run without a prompt.
    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview?
    /// Whether the tool is always offered to the model, even when progressive
    /// disclosure trims the set to a relevant subset (like `find_tools`).
    var alwaysVisible: Bool { get }
    /// `argumentsJSON` is the raw JSON the model produced for the call.
    /// Returns content for the model (markdown/text). Throwing is caught by the registry.
    func execute(argumentsJSON: String) async throws -> String
}

extension Tool {
    var isMutating: Bool { false }
    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? { nil }
    var alwaysVisible: Bool { false }
}

/// A preview of a pending mutating tool call, surfaced in the in-chat approval card.
struct ToolApprovalPreview: Sendable, Equatable, Identifiable {
    /// `external`: a tool from a user-configured MCP server.
    enum Kind: Sendable, Equatable { case write, edit, shell, external }
    let id = UUID()
    let kind: Kind
    /// Everything but shell may be approved for a whole session: a shell grant would
    /// authorize every later command (that's what YOLO is for). Writes/edits are
    /// workspace-scoped; an MCP grant covers that one server's tool (`grantKey`), so long
    /// research doesn't need a click per fetch.
    var allowsSessionGrant: Bool { kind != .shell }
    let title: String    // e.g. "Write src/notes.md" or "Run command"
    let detail: String   // file content, a diff, or the shell command — shown monospaced
    /// What a session grant is remembered under, when the tool name alone is ambiguous:
    /// MCP tools use "mcp:<server>/<tool>", since the Filesystem server's `write_file`
    /// (rooted at ~) shares its name with the workspace-scoped built-in. nil = tool name.
    var grantKey: String? = nil
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
