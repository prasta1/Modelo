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
    case needsPath                    // point it at a folder / db / repo
    case needsKey(envs: [String])     // requires API keys in the named env vars
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
    /// For `needsKey` entries the env dict is pre-seeded with empty values so the
    /// key fields appear immediately in the settings row.
    func makeConfig(isEnabled: Bool = false) -> MCPServerConfig {
        var envDict: [String: String] = [:]
        if case .needsKey(let envVars) = setup {
            for envVar in envVars { envDict[envVar] = "" }
        }
        return MCPServerConfig(name: name, command: command, arguments: arguments,
                               env: envDict, isEnabled: isEnabled)
    }

    /// Lowercased haystack for substring search.
    var searchText: String { "\(name) \(summary) \(category)".lowercased() }
}

/// The built-in, hand-curated catalog of well-known MCP servers, each carrying the
/// exact command line needed to launch it.
struct BundledMCPCatalog: Sendable {
    func load() async -> [MCPCatalogEntry] { Self.entries }

    static let entries: [MCPCatalogEntry] = [
        MCPCatalogEntry(id: "filesystem", name: "Filesystem",
            summary: "Sandboxed read/write access to a folder.",
            category: "Files", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()],
            setup: .needsPath),
        MCPCatalogEntry(id: "markitdown", name: "MarkItDown",
            summary: "Convert PDF, Office, and other documents to markdown.",
            category: "Files", command: "uvx",
            arguments: ["markitdown-mcp"],
            setup: .none),
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
        MCPCatalogEntry(id: "playwright", name: "Playwright",
            summary: "Drive a real browser via its accessibility tree — navigate, click, extract.",
            category: "Web", command: "npx",
            arguments: ["-y", "@playwright/mcp@latest"],
            setup: .none),
        MCPCatalogEntry(id: "git", name: "Git",
            summary: "Inspect a local git repository — log, diff, show.",
            category: "Dev", command: "uvx",
            arguments: ["mcp-server-git", "--repository", NSHomeDirectory()],
            setup: .needsPath),
        MCPCatalogEntry(id: "context7", name: "Context7",
            summary: "Up-to-date documentation for libraries and frameworks.",
            category: "Dev", command: "npx",
            arguments: ["-y", "@upstash/context7-mcp"],
            setup: .none),
        MCPCatalogEntry(id: "github", name: "GitHub",
            summary: "Official GitHub server — repos, issues, PRs. Install: brew install github-mcp-server.",
            category: "Dev", command: "github-mcp-server",
            arguments: ["stdio"],
            setup: .needsKey(envs: ["GITHUB_PERSONAL_ACCESS_TOKEN"])),
        MCPCatalogEntry(id: "apple-mcp", name: "Apple Apps",
            summary: "Notes, Reminders, Calendar, Messages, and Maps. Requires Bun; prompts for Automation access.",
            category: "Mac", command: "bunx",
            arguments: ["apple-mcp"],
            setup: .none),
        MCPCatalogEntry(id: "notion", name: "Notion",
            summary: "Read and write Notion pages, databases, and blocks via the official Notion API.",
            category: "Dev", command: "npx",
            arguments: ["-y", "@notionhq/notion-mcp-server"],
            setup: .needsKey(envs: ["OPENAPI_MCP_HEADERS"])),
        MCPCatalogEntry(id: "linear", name: "Linear",
            summary: "Find, create, and update Linear issues, projects, and comments. Opens a browser for OAuth on first use.",
            category: "Dev", command: "npx",
            arguments: ["-y", "mcp-remote", "https://mcp.linear.app/mcp"],
            setup: .none),
        MCPCatalogEntry(id: "slack", name: "Slack",
            summary: "Search channels, read threads, and send Slack messages. Opens a browser for OAuth on first use.",
            category: "Dev", command: "npx",
            arguments: ["-y", "mcp-remote", "https://mcp.slack.com/mcp"],
            setup: .none),
        MCPCatalogEntry(id: "hubspot", name: "HubSpot",
            summary: "Read and write HubSpot CRM contacts, deals, and engagements. Opens a browser for OAuth on first use.",
            category: "Dev", command: "npx",
            arguments: ["-y", "mcp-remote", "https://mcp.hubspot.com"],
            setup: .none),
        MCPCatalogEntry(id: "huggingface", name: "Hugging Face",
            summary: "Browse models, datasets, and Spaces on Hugging Face Hub. Opens a browser for OAuth on first use.",
            category: "Dev", command: "npx",
            arguments: ["-y", "mcp-remote", "https://huggingface.co/mcp"],
            setup: .none),
        MCPCatalogEntry(id: "gdrive", name: "Google Drive",
            summary: "Search and read Google Drive files (Docs → Markdown, Sheets → CSV). Requires a Google Cloud OAuth keys file; set GDRIVE_OAUTH_PATH to its path.",
            category: "Files", command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-gdrive"],
            setup: .needsKey(envs: ["GDRIVE_OAUTH_PATH"])),
    ]
}

// MARK: - Registry search

/// Searches the official MCP Registry (registry.modelcontextprotocol.io) and maps
/// hits onto `MCPCatalogEntry`, so remote results flow through the same discovery
/// UI and add flow as the bundled catalog.
///
/// Modelo launches MCP servers as stdio subprocesses, so only servers publishing a
/// stdio-capable npm or PyPI package are returned — remote-only (HTTP/SSE) servers
/// are filtered out.
struct MCPRegistrySearch: Sendable {
    /// Query the registry and return launchable entries in registry order.
    /// - Parameter query: free text, matched against server names and descriptions.
    func search(_ query: String) async throws -> [MCPCatalogEntry] {
        var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0/servers")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.servers.compactMap { Self.entry(for: $0.server) }
    }

    /// Map one registry server to a catalog entry, or nil if it publishes no
    /// package Modelo can launch (npm → npx, pypi → uvx; stdio transport only).
    private static func entry(for server: Server) -> MCPCatalogEntry? {
        guard let package = (server.packages ?? []).first(where: { pkg in
            (pkg.transport?.type ?? "stdio") == "stdio"
                && (pkg.registryType == "npm" || pkg.registryType == "pypi")
                && pkg.identifier != nil
        }), let identifier = package.identifier else { return nil }

        let (command, arguments) = package.registryType == "npm"
            ? ("npx", ["-y", identifier])
            : ("uvx", [identifier])
        let requiredEnvs = (package.environmentVariables ?? [])
            .filter { $0.isRequired ?? false }
            .map(\.name)
        // Registry names are reverse-DNS ("io.github.owner/repo") — show the last
        // path component unless the server declares a human-readable title.
        let displayName = server.title
            ?? server.name.split(separator: "/").last.map(String.init)
            ?? server.name
        return MCPCatalogEntry(
            id: server.name,
            name: displayName,
            summary: server.description ?? "",
            category: "Registry",
            command: command,
            arguments: arguments,
            setup: requiredEnvs.isEmpty ? .none : .needsKey(envs: requiredEnvs))
    }

    // Decodable slices of the registry response — only the fields Modelo uses.
    // Everything but the server name is optional so one sparse record can't sink
    // the whole result list.
    private struct Response: Decodable { let servers: [Record] }
    private struct Record: Decodable { let server: Server }
    private struct Server: Decodable {
        let name: String
        let title: String?
        let description: String?
        let packages: [Package]?
    }
    private struct Package: Decodable {
        let registryType: String?
        let identifier: String?
        let transport: Transport?
        let environmentVariables: [EnvVar]?
    }
    private struct Transport: Decodable { let type: String? }
    private struct EnvVar: Decodable {
        let name: String
        let isRequired: Bool?
    }
}
