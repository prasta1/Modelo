import SwiftUI
import Observation

// NOTE: This file is a NEW addition the handoff (§2) calls for — add it to the
// "Modelo" target in Xcode. It is the single source of truth the chip, picker,
// settings default-model, etc. all bind to.

/// Top-level navigation. The "models" tab shows Chat (handoff §2).
enum AppSection: Hashable {
    case models, status, reports, settings
}

// MARK: - Console (Status)

enum LogLevel: String {
    case info = "INFO", post = "POST", warn = "WARN", mcp = "MCP", ping = "PING"
    var color: Color {
        switch self {
        case .info, .ping: return Theme.green
        case .post:        return Theme.blue
        case .warn:        return Theme.amber
        case .mcp:         return Theme.purple
        }
    }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    var time: String
    var level: LogLevel
    var message: String
}

// MARK: - Reports

struct StatTile: Identifiable, Hashable {
    let id = UUID()
    var label: String           // "TOKENS"
    var value: String           // "1.24M"
    var sub: String             // "+12% vs prev"
}

struct ChartSample: Identifiable, Hashable {
    let id = UUID()
    var index: Int
    var value: Double
}

struct UsageRow: Identifiable, Hashable {
    let id = UUID()
    var model: String
    var requests: String
    var tokens: String
    var rate: String
    var share: Double           // 0…1
    var sharePercent: String    // "62%"
}

// MARK: - Settings

struct EndpointRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var url: String
    var type: String            // "LM Studio" / "Cloud"
    var enabled: Bool
}

struct BehaviorToggle: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var isOn: Bool
}

// MARK: - Store

@Observable
final class AppStore {

    // Navigation
    var section: AppSection = .models

    // Sidebar servers + selection (shared source of truth)
    var servers: [Server]
    var activeServerID: Server.ID

    // Models / current selection
    var models: [ModelInfo]
    var selectedModelID: ModelInfo.ID

    // Model Browser
    var catalog: [CatalogModel]
    var personas: [Persona]
    var activePersonaID: Persona.ID?

    // Conversations
    var conversations: [Conversation]

    // Chat
    var messages: [ChatMessage]
    var composerDraft: String = "Make it rhyme this time"
    var tokensUsed: Int = 24_300
    var contextWindow: Int = 262_000

    // Status
    var statusServers: [ServerStat]
    var consoleLines: [LogLine]
    var consoleFilter: String = "All"

    // Reports
    var reportRange: String = "7 days"
    var stats: [StatTile]
    var throughput: [ChartSample]
    var ttft: [ChartSample]
    var usage: [UsageRow]

    // Settings
    var settingsSection: String = "Servers"
    let settingsSections = ["General", "Servers", "Models", "Tools · MCP",
                            "API Keys", "Appearance", "Personas"]
    var endpoints: [EndpointRow]
    var behaviors: [BehaviorToggle]
    var defaultModel = "qwen3-coder"
    var apiKeyMasked = "sk-or-••••••••••••••4f2a"

    // MARK: Derived

    var selectedModel: ModelInfo? { models.first { $0.id == selectedModelID } }
    var contextFraction: Double {
        contextWindow == 0 ? 0 : Double(tokensUsed) / Double(contextWindow)
    }
    var liveServerCount: Int { servers.filter(\.isLive).count }

    /// Servers in declared order, each with its models — the picker's `Section`s.
    var modelGroups: [(server: Server, models: [ModelInfo])] {
        servers.map { srv in
            (srv, models.filter { $0.serverID == srv.id })
        }
    }

    func selectModel(_ model: ModelInfo) {
        selectedModelID = model.id
        // Promote the chosen model; previous selection drops back to loaded.
        for i in models.indices {
            if models[i].state == .selected { models[i].state = .loaded }
        }
        if let i = models.firstIndex(where: { $0.id == model.id }), model.state != .cloud {
            models[i].state = .selected
        }
    }

    // MARK: Seed (sample frames from the mock — replace with live streams)

    init() {
        // Servers ---------------------------------------------------------
        let studio = Server(name: "Mac Studio M3 Ultra",
                            host: "studio.taile85139.ts.net:1234",
                            kind: .lmStudio, pickerMeta: "4 loaded")
        let macbook = Server(name: "Macbook Pro M5",
                             host: "localhost:1234",
                             kind: .lmStudio, pickerMeta: "1 loaded")
        let router = Server(name: "OpenRouter",
                            host: ":0",
                            kind: .cloud, pickerMeta: "connected")
        servers = [studio, macbook, router]
        activeServerID = studio.id

        // Models (grouped under servers) ----------------------------------
        let m = [
            ModelInfo(name: "qwen3-coder",  meta: "30B · MLX · 4bit",   contextLabel: "262K", state: .selected, serverID: studio.id),
            ModelInfo(name: "qwen3.6",      meta: "32B · MLX · 4bit",   contextLabel: "128K", state: .loaded,   serverID: studio.id),
            ModelInfo(name: "qwen3-vl",     meta: "8B · MLX · 6bit",    contextLabel: "32K",  state: .loaded,   serverID: studio.id),
            ModelInfo(name: "gpt-oss-120b", meta: "120B · GGUF · MXFP4", contextLabel: "128K", state: .idle,    serverID: studio.id),
            ModelInfo(name: "granite-4.0-h-tiny", meta: "7B · MLX · 4bit", contextLabel: "128K", state: .loaded, serverID: macbook.id),
            ModelInfo(name: "gemma-3-12b",  meta: "12B · GGUF · Q4_K_M", contextLabel: "8K",   state: .idle,    serverID: macbook.id),
            ModelInfo(name: "claude-opus-4.6", meta: "cloud · metered", contextLabel: "500K", state: .cloud,    serverID: router.id),
            ModelInfo(name: "kimi-k2",      meta: "cloud · metered",   contextLabel: "200K", state: .cloud,    serverID: router.id),
        ]
        models = m
        selectedModelID = m[0].id

        // Model Browser catalog (frame 01) --------------------------------
        catalog = [
            CatalogModel(name: "qwen3-coder",              specs: "30B   ·   4bit   ·   262K ctx", capabilities: ["REASON"], isLoaded: true),
            CatalogModel(name: "granite-4.0-h-tiny@8bit",  specs: "8bit   ·   131K ctx",            capabilities: [],         isLoaded: true),
            CatalogModel(name: "granite-4.0-h-tiny@8bit:2", specs: "8bit   ·   131K ctx",           capabilities: [],         isLoaded: true),
            CatalogModel(name: "qwen3.6",                  specs: "27B   ·   4bit   ·   262K ctx",  capabilities: ["VISION", "REASON"], isLoaded: true),
            CatalogModel(name: "gpt-oss",                  specs: "120B   ·   MXFP4   ·   131K ctx", capabilities: [],        isLoaded: false),
            CatalogModel(name: "granite-4.0-h-tiny@4bit",  specs: "4bit   ·   131K ctx",            capabilities: [],         isLoaded: false),
            CatalogModel(name: "qwen3-vl",                 specs: "30B   ·   4bit   ·   262K ctx",  capabilities: ["VISION", "REASON"], isLoaded: false),
            CatalogModel(name: "qwen3-vl",                 specs: "4B   ·   4bit   ·   262K ctx",   capabilities: ["VISION", "REASON"], isLoaded: false),
            CatalogModel(name: "qwen3-2507",               specs: "30B   ·   4bit   ·   262K ctx",  capabilities: ["REASON"], isLoaded: false),
        ]
        personas = [
            Persona(name: "Customer Support", traits: "Helpful · Patient · Empathetic"),
            Persona(name: "Coding",           traits: "Precise · Pragmatic · Senior"),
            Persona(name: "Researcher",       traits: "Thorough · Cited · Balanced"),
            Persona(name: "Investor",         traits: "Analytical · Risk-aware · Data-driven"),
        ]

        // Conversations ---------------------------------------------------
        conversations = [
            Conversation(title: "100 Words on Tacos", time: "21:24"),
            Conversation(title: "New Chat",           time: "21:23"),
            Conversation(title: "Taco Conversation",  time: "21:22"),
            Conversation(title: "Explosive Entrance", time: "21:19"),
        ]

        // Chat ------------------------------------------------------------
        messages = [
            ChatMessage(role: .user,
                        text: "Write exactly 100 words on why tacos are the perfect food — make it vivid."),
            ChatMessage(role: .assistant,
                        text: "Few foods carry a whole culture in a single bite. The tortilla is both plate and vessel — warm, pliant, forgiving. Inside, contrast does the work: crisp against tender, bright lime against deep char, cool crema against smoke. A taco asks nothing of you but appetite, and returns everything. Cheap, fast, endlessly variable — handheld proof that the best things rarely need a fork.",
                        modelName: "qwen3-coder",
                        timestamp: "21:24",
                        toolCall: ToolCall(title: "Searched the web",
                                           detail: "\u{201C}taco history\u{201D} · 3 sources"),
                        metrics: MessageMetrics(ttft: "TTFT 240ms", rate: "42 tok/s", tokens: "312 tokens")),
            ChatMessage(role: .user, text: "Now do it in 50 words."),
            ChatMessage(role: .assistant,
                        text: "A taco is contrast you can hold. Warm tortilla, charred edge, bright lime, cool crema — every bite trades crisp for tender",
                        modelName: "qwen3-coder",
                        isStreaming: true),
        ]

        // Status ----------------------------------------------------------
        statusServers = [
            ServerStat(name: "Mac Studio M3 Ultra", host: "studio.taile85139.ts.net:1234",
                       latency: "12 ms", models: "4 loaded", requests: "38 / min", throughput: "42 tok/s",
                       spark: [40,55,48,62,52,70,58,66,60,74,63,68,57,80,66,72,61,78]),
            ServerStat(name: "Macbook Pro M5", host: "localhost:1234",
                       latency: "8 ms", models: "1 loaded", requests: "6 / min", throughput: "51 tok/s",
                       spark: [30,42,38,50,44,58,40,62,48,55,46,60,50,64,52,58,44,66]),
            ServerStat(name: "OpenRouter", host: "openrouter.ai/api/v1",
                       latency: "240 ms", models: "cloud", requests: "2 / min", throughput: "28 tok/s",
                       spark: [20,28,24,34,30,26,38,22,30,36,28,32,24,40,30,26,34,30]),
        ]
        consoleLines = [
            LogLine(time: "12:04:51", level: .info, message: "qwen3-coder loaded in 3.2s"),
            LogLine(time: "12:04:53", level: .post, message: "/v1/chat/completions → 200 · 1.2s"),
            LogLine(time: "12:05:01", level: .warn, message: "context 92% full — truncating oldest turns"),
            LogLine(time: "12:05:02", level: .info, message: "stream complete · 1203 tok · 42 tok/s"),
            LogLine(time: "12:05:14", level: .ping, message: "reachability ok · 12ms rtt"),
            LogLine(time: "12:05:20", level: .post, message: "/v1/chat/completions → 200 · 0.9s"),
            LogLine(time: "12:05:33", level: .mcp,  message: "firecrawl.search → 3 results"),
            LogLine(time: "12:05:34", level: .info, message: "tool result injected · 842 tok"),
            LogLine(time: "12:05:41", level: .post, message: "/v1/embeddings → 200 · 0.3s"),
            LogLine(time: "12:05:55", level: .info, message: "qwen3.6 warm · kv-cache 18%"),
        ]

        // Reports ---------------------------------------------------------
        stats = [
            StatTile(label: "TOKENS",     value: "1.24M",    sub: "+12% vs prev"),
            StatTile(label: "REQUESTS",   value: "482",      sub: "68 today"),
            StatTile(label: "AVG TTFT",   value: "280 ms",   sub: "8% faster"),
            StatTile(label: "THROUGHPUT", value: "44 tok/s", sub: "peak 88"),
            StatTile(label: "EST. COST",  value: "$0.00",    sub: "local · free"),
        ]
        let tput = [38,52,44,61,49,72,58,66,55,78,63,70,59,82,68,74,61,88,71,66,57,79,64,60,52,73,67,80]
        throughput = tput.enumerated().map { ChartSample(index: $0.offset, value: Double($0.element)) }
        let ttftVals = [320,300,285,295,262,250,272,240,256,232,246,236,252,226,242,262,236,222,248,256,242,232,252,266,246,236,250,238]
        ttft = ttftVals.enumerated().map { ChartSample(index: $0.offset, value: Double($0.element)) }
        usage = [
            UsageRow(model: "qwen3-coder",        requests: "184", tokens: "612K", rate: "46", share: 0.62, sharePercent: "62%"),
            UsageRow(model: "qwen3.6",            requests: "98",  tokens: "304K", rate: "52", share: 0.31, sharePercent: "31%"),
            UsageRow(model: "gpt-oss",            requests: "71",  tokens: "198K", rate: "21", share: 0.20, sharePercent: "20%"),
            UsageRow(model: "granite-4.0-h-tiny", requests: "54",  tokens: "88K",  rate: "61", share: 0.09, sharePercent: "9%"),
            UsageRow(model: "qwen3-vl",           requests: "33",  tokens: "42K",  rate: "38", share: 0.04, sharePercent: "4%"),
        ]

        // Settings --------------------------------------------------------
        endpoints = [
            EndpointRow(name: "Mac Studio M3 Ultra", url: "studio.taile85139.ts.net:1234", type: "LM Studio", enabled: true),
            EndpointRow(name: "Macbook Pro M5",      url: "localhost:1234",                type: "LM Studio", enabled: true),
            EndpointRow(name: "OpenRouter",          url: "openrouter.ai/api/v1",          type: "Cloud",     enabled: true),
        ]
        behaviors = [
            BehaviorToggle(label: "Auto-load last model on launch", isOn: true),
            BehaviorToggle(label: "Stream responses token-by-token", isOn: true),
            BehaviorToggle(label: "Record usage metrics locally", isOn: true),
            BehaviorToggle(label: "Send anonymous telemetry", isOn: false),
        ]
    }
}
