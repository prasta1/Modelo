import Foundation

/// Configuration for one MCP server process. Stored as JSON in UserDefaults.
struct MCPServerConfig: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Executable to run — resolved against PATH and common Homebrew locations at launch.
    var command: String
    /// Arguments after the command (e.g. ["-y", "@modelcontextprotocol/server-filesystem", "/path"]).
    var arguments: [String]
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, command: String = "npx",
         arguments: [String] = [], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.isEnabled = isEnabled
    }

    /// The full command line as a single string — displayed in the settings row.
    var commandLine: String { ([command] + arguments).joined(separator: " ") }
}

// MARK: - UserDefaults persistence

extension MCPServerConfig {
    private static let defaultsKey = "mcpServers"

    static func loadAll() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return [] }
        return list
    }

    static func saveAll(_ configs: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
