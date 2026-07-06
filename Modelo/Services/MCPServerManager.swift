import Foundation

// MARK: - Tool adapter

/// Wraps one discovered MCP tool as a `Tool` conformer, routing `execute` calls
/// back to the owning `MCPClient` actor.
struct MCPTool: Tool {
    let name: String
    let description: String
    let parameters: JSONSchema
    private let client: MCPClient  // actor — implicitly Sendable

    init(name: String, description: String, parameters: JSONSchema, client: MCPClient) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.client = client
    }

    /// Hard cap on the characters of one MCP tool result forwarded to the model.
    /// First-party tools each bound their own output (BashTool clips at the same
    /// figure), but an external server can return anything — `directory_tree` on a
    /// large folder yields megabytes of JSON that would ride the conversation into
    /// every subsequent request and blow the context window (~4 chars ≈ 1 token,
    /// so 30k chars ≈ 7.5k tokens).
    static let resultCharacterLimit = 30_000

    /// Returns `text` unchanged when within the cap, else its head plus a note
    /// telling the model the result was clipped so it can ask for something
    /// narrower on the next round.
    static func clipped(_ text: String) -> String {
        guard text.count > resultCharacterLimit else { return text }
        return text.prefix(resultCharacterLimit)
            + "\n… (result truncated: \(text.count) characters exceeds the \(resultCharacterLimit)-character limit — request something narrower, e.g. a subdirectory or a smaller range)"
    }

    func execute(argumentsJSON: String) async throws -> String {
        Self.clipped(try await client.callTool(name: name, argumentsJSON: argumentsJSON))
    }
}

// MARK: - Manager

/// Owns the lifecycle of all configured MCP server processes and exposes their
/// combined tool set as `availableTools`. Lives on the main actor so SwiftUI
/// can observe it directly.
@MainActor
@Observable
final class MCPServerManager {
    private(set) var configs: [MCPServerConfig] = MCPServerConfig.loadAll()
    private(set) var availableTools: [any Tool] = []
    /// Per-server error strings for display in the settings UI.
    private(set) var connectionErrors: [UUID: String] = [:]

    private var clients: [UUID: MCPClient] = [:]

    // MARK: App lifecycle

    func startAll() {
        for config in configs where config.isEnabled {
            Task { await launch(config) }
        }
    }

    func stopAll() async {
        for (_, client) in clients { await client.disconnect() }
        clients = [:]
        availableTools = []
    }

    // MARK: Config CRUD

    func addConfig(_ config: MCPServerConfig) {
        configs.append(config)
        persist()
        if config.isEnabled { Task { await launch(config) } }
    }

    func removeConfig(id: UUID) {
        if let client = clients.removeValue(forKey: id) {
            Task { await client.disconnect() }
        }
        configs.removeAll { $0.id == id }
        connectionErrors.removeValue(forKey: id)
        persist()
        Task { await rebuildTools() }
    }

    func updateConfig(_ updated: MCPServerConfig) {
        guard let idx = configs.firstIndex(where: { $0.id == updated.id }) else { return }
        configs[idx] = updated
        persist()
        // Tear down the existing client and reconnect with the new config.
        if let existing = clients.removeValue(forKey: updated.id) {
            Task {
                await existing.disconnect()
                if updated.isEnabled { await self.launch(updated) }
                else { await self.rebuildTools() }
            }
        } else if updated.isEnabled {
            Task { await launch(updated) }
        }
    }

    // MARK: Private

    private func launch(_ config: MCPServerConfig) async {
        let client = MCPClient(config: config)
        do {
            try await client.connect()
            clients[config.id] = client
            connectionErrors.removeValue(forKey: config.id)
        } catch {
            Log.mcp.error("MCP server \(config.name, privacy: .public) failed to connect: \(error.localizedDescription, privacy: .public)")
            connectionErrors[config.id] = error.localizedDescription
        }
        await rebuildTools()
    }

    private func rebuildTools() async {
        var tools: [any Tool] = []
        for (id, client) in clients {
            guard configs.first(where: { $0.id == id })?.isEnabled == true else { continue }
            let defs = await client.toolDefs
            for def in defs {
                tools.append(MCPTool(name: def.name, description: def.description,
                                     parameters: def.parameters, client: client))
            }
        }
        availableTools = tools
    }

    private func persist() { MCPServerConfig.saveAll(configs) }
}
