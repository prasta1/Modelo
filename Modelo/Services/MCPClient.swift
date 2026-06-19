import Foundation

// MARK: - Error type

enum MCPError: Error, LocalizedError {
    case notConnected
    case launchFailed(String)
    case protocolError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:         return "MCP server not connected"
        case .launchFailed(let m):  return "MCP launch failed: \(m)"
        case .protocolError(let m): return "MCP protocol error: \(m)"
        case .serverError(let m):   return m
        }
    }
}

// MARK: - Tool definition

/// A tool surfaced by an MCP server, ready to be wrapped as a `Tool` conformer.
struct MCPToolDef: Sendable {
    let name: String
    let description: String
    let parameters: JSONSchema
}

// MARK: - Client actor

/// JSON-RPC 2.0 over stdio for one MCP server process.
///
/// Lifecycle: `connect()` spawns the process and runs the MCP handshake. After a
/// successful connect, `toolDefs` holds the server's tool catalogue. `callTool`
/// executes a named tool and returns the text content. `disconnect()` kills the
/// process and cleans up.
actor MCPClient {
    let config: MCPServerConfig
    private(set) var toolDefs: [MCPToolDef] = []
    private(set) var isConnected = false

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var lineBuffer = ""
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(config: MCPServerConfig) { self.config = config }

    // MARK: Connect / disconnect

    func connect() async throws {
        let p = Process()
        p.executableURL = try Self.resolve(command: config.command)
        p.arguments = config.arguments

        // Augment PATH so npx/node resolves at runtime in a GUI process context.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = "\(extra):\(env["PATH"] ?? "/usr/bin:/bin")"
        p.environment = env

        let inPipe  = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput  = inPipe
        p.standardOutput = outPipe
        p.standardError  = errPipe

        stdinHandle  = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading

        // Drain stderr so a chatty server never blocks on a full pipe.
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }

        // Route stdout chunks into the actor's line buffer.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { await self?.ingest(text) }
        }

        try p.run()
        process = p

        // MCP handshake: initialize → initialized notification → tools/list
        let initResult = try await rpc("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Modelo", "version": "1.0"]
        ])
        guard initResult["protocolVersion"] != nil else {
            throw MCPError.protocolError("Missing protocolVersion in initialize response")
        }
        notify("notifications/initialized")

        let toolsResult = try await rpc("tools/list")
        if let raw = toolsResult["tools"] as? [[String: Any]] {
            toolDefs = raw.compactMap(Self.parseTool)
        }
        isConnected = true
    }

    func disconnect() {
        isConnected = false
        stdoutHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinHandle  = nil
        stdoutHandle = nil
        toolDefs = []
        for (_, c) in pending { c.resume(throwing: MCPError.notConnected) }
        pending = [:]
    }

    // MARK: Tool call

    /// Calls a named tool with the model's raw JSON argument string.
    func callTool(name: String, argumentsJSON: String) async throws -> String {
        var params: [String: Any] = ["name": name]
        if let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
           !args.isEmpty {
            params["arguments"] = args
        }
        let result = try await rpc("tools/call", params: params)
        let isError = result["isError"] as? Bool ?? false
        let text = (result["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if isError { throw MCPError.serverError(text.isEmpty ? "Tool returned an error" : text) }
        return text.isEmpty ? "(no output)" : text
    }

    // MARK: JSON-RPC internals

    private func rpc(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        try writeMsg(msg)
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    private func notify(_ method: String, params: [String: Any]? = nil) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        try? writeMsg(msg)
    }

    private func writeMsg(_ msg: [String: Any]) throws {
        guard let handle = stdinHandle else { throw MCPError.notConnected }
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)  // newline frame delimiter
        handle.write(data)
    }

    private func ingest(_ text: String) {
        lineBuffer += text
        while let nl = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<nl.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = String(lineBuffer[nl.upperBound...])
            guard !line.isEmpty else { continue }
            dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id   = json["id"] as? Int,
              let cont = pending.removeValue(forKey: id) else { return }

        if let err = json["error"] as? [String: Any] {
            cont.resume(throwing: MCPError.serverError(err["message"] as? String ?? "Unknown MCP error"))
        } else {
            cont.resume(returning: json["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: Helpers

    private static func resolve(command: String) throws -> URL {
        if command.hasPrefix("/") { return URL(fileURLWithPath: command) }
        // GUI apps inherit a stripped PATH — supplement with common install paths.
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extras  = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
        let dirs = (envPath + ":" + extras).split(separator: ":").map(String.init)
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw MCPError.launchFailed("'\(command)' not found in PATH — install it or use a full path")
    }

    /// Converts a raw MCP tool definition dict into the app's JSONSchema type.
    /// Unsupported property types fall back to "string".
    private static func parseTool(_ raw: [String: Any]) -> MCPToolDef? {
        guard let name = raw["name"] as? String else { return nil }
        let desc   = raw["description"] as? String ?? ""
        let schema = raw["inputSchema"] as? [String: Any] ?? [:]
        var props: [String: JSONSchema.Property] = [:]
        if let rawProps = schema["properties"] as? [String: [String: Any]] {
            for (key, def) in rawProps {
                props[key] = JSONSchema.Property(
                    def["type"] as? String ?? "string",
                    def["description"] as? String
                )
            }
        }
        let required = schema["required"] as? [String] ?? []
        return MCPToolDef(name: name, description: desc,
                          parameters: JSONSchema(properties: props, required: required))
    }
}
