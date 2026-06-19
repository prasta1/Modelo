import Foundation

/// Configuration for one MCP server process. Stored as JSON in UserDefaults.
struct MCPServerConfig: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Executable to run — resolved against PATH and common Homebrew locations at launch.
    var command: String
    /// Arguments after the command (e.g. ["-y", "@modelcontextprotocol/server-filesystem", "/path"]).
    var arguments: [String]
    /// Environment variables injected into the server process at launch (e.g. API keys).
    /// Keys are env var names; empty-string values are stored but not passed to the process.
    var env: [String: String]
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, command: String = "npx",
         arguments: [String] = [], env: [String: String] = [:], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.env = env
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

// MARK: - Discovery catalog

/// What a catalog entry needs before it can actually connect — surfaced as a hint
/// in the discovery UI. `MCPServerConfig` has no env-var field yet, so `.needsKey`
/// servers are prefilled but the user must supply the secret another way.
enum MCPSetup: Equatable, Sendable {
    case none
    case needsPath                 // point it at a folder / db / repo
    case needsKey(env: String)     // requires an API key in the named env var
}

/// One known MCP server in the bundled discovery catalog. Converts to a
/// ready-to-run `MCPServerConfig` via `makeConfig`.
struct MCPCatalogEntry: Identifiable, Sendable {
    let id: String                 // stable slug, e.g. "github"
    let name: String               // "GitHub"
    let summary: String            // one-line description
    let category: String           // "Files" / "Web" / "Dev" …
    let command: String            // "npx" / "uvx"
    let arguments: [String]
    let setup: MCPSetup

    /// A config ready to hand to `MCPServerManager.addConfig`. Added disabled by
    /// default so the user can adjust paths/keys before it launches.
    /// For `needsKey` entries the env dict is pre-seeded with an empty value so the
    /// key field appears immediately in the settings row.
    func makeConfig(isEnabled: Bool = false) -> MCPServerConfig {
        var envDict: [String: String] = [:]
        if case .needsKey(let envVar) = setup { envDict[envVar] = "" }
        return MCPServerConfig(name: name, command: command, arguments: arguments,
                               env: envDict, isEnabled: isEnabled)
    }

    /// Lowercased haystack for substring search.
    var searchText: String { "\(name) \(summary) \(category)".lowercased() }
}

/// Source of discoverable MCP servers. Bundled today; a live registry client could
/// conform later (loading entries over the network) and the discovery UI would not
/// have to change.
protocol MCPCatalogSource: Sendable {
    func load() async -> [MCPCatalogEntry]
}

/// The built-in, hand-curated catalog of well-known MCP servers, each carrying the
/// exact command line needed to launch it.
struct BundledMCPCatalog: MCPCatalogSource {
    func load() async -> [MCPCatalogEntry] { Self.entries }

    static let entries: [MCPCatalogEntry] = [
        MCPCatalogEntry(id: "filesystem", name: "Filesystem",
            summary: "Sandboxed read/write access to a folder.",
            category: "Files", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()],
            setup: .needsPath),
        MCPCatalogEntry(id: "memory", name: "Memory",
            summary: "Persistent knowledge-graph memory across chats.",
            category: "Reasoning", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-memory"],
            setup: .none),
        MCPCatalogEntry(id: "sequential-thinking", name: "Sequential Thinking",
            summary: "A structured step-by-step reasoning scratchpad.",
            category: "Reasoning", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
            setup: .none),
        MCPCatalogEntry(id: "fetch", name: "Fetch",
            summary: "Fetch a URL and convert it to clean markdown.",
            category: "Web", command: "uvx",
            arguments: ["mcp-server-fetch"],
            setup: .none),
        MCPCatalogEntry(id: "puppeteer", name: "Puppeteer",
            summary: "Drive a headless browser — navigate, click, screenshot.",
            category: "Web", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-puppeteer"],
            setup: .none),
        MCPCatalogEntry(id: "git", name: "Git",
            summary: "Inspect a local git repository — log, diff, show.",
            category: "Dev", command: "uvx",
            arguments: ["mcp-server-git", "--repository", NSHomeDirectory()],
            setup: .needsPath),
        MCPCatalogEntry(id: "sqlite", name: "SQLite",
            summary: "Run read-only queries against a SQLite database.",
            category: "Data", command: "uvx",
            arguments: ["mcp-server-sqlite", "--db-path", "/path/to/database.db"],
            setup: .needsPath),
        MCPCatalogEntry(id: "github", name: "GitHub",
            summary: "Browse repos, issues, and pull requests.",
            category: "Dev", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-github"],
            setup: .needsKey(env: "GITHUB_PERSONAL_ACCESS_TOKEN")),
        MCPCatalogEntry(id: "brave-search", name: "Brave Search",
            summary: "Web and local search via the Brave API.",
            category: "Web", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-brave-search"],
            setup: .needsKey(env: "BRAVE_API_KEY")),
        MCPCatalogEntry(id: "slack", name: "Slack",
            summary: "Read channels and post messages in a workspace.",
            category: "Chat", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-slack"],
            setup: .needsKey(env: "SLACK_BOT_TOKEN")),
    ]
}
