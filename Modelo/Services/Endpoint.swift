import Foundation
import SwiftData

/// Which kind of backend a `Server` row points at.
/// - `lmStudio`: a local LM Studio machine (host:port over HTTP, no auth, rich `/api/v0`).
/// - `llamaCpp`: a raw llama.cpp server (llama-server; host:port, OpenAI-compatible `/v1`, no `/api/v0`).
/// - `llamaSwap`: a llama-swap reverse proxy that routes model requests to multiple llama.cpp
///   backends. Same wire shape as `llamaCpp`; distinct in label, icon, and setup guidance.
/// - `oMLX`: a local oMLX server (omlx.ai) — an Apple-silicon MLX runtime. Same wire
///   shape as `llamaCpp` (host:port, OpenAI-compatible `/v1`); distinct only in label/port.
/// - `cloudAPI`: any OpenAI-compatible cloud endpoint (user-supplied HTTPS base URL, bearer auth).
/// - `openRouter`: hardcoded OpenRouter cloud endpoint — user supplies only the API key.
/// - `nous`: hardcoded Nous Research inference endpoint — user supplies only the API key.
///
/// `lmStudio`, `llamaCpp`, `llamaSwap`, `oMLX`, `ollama`, and `exo` are *local* (self-hosted) —
/// they run on hardware you control and can have a `modelo-tap` GPU agent next to them.
enum ServerKind: String, Codable, Sendable, CaseIterable {
    case lmStudio
    /// Raw value kept as "llamaSwap" so servers saved before the rename still deserialise.
    case llamaCpp = "llamaSwap"
    /// Dedicated llama-swap proxy kind. Wire-identical to llamaCpp but
    /// displayed as "llama-swap" with a proxy-specific setup hint.
    case llamaSwap = "llamaSwapProxy"
    case oMLX
    /// Local Ollama runtime — OpenAI-compatible /v1, default port 11434.
    case ollama
    /// Local exo cluster runtime — OpenAI-compatible /v1, default port 52415.
    /// exo's /v1/models lists its whole downloadable catalog, so model fetching
    /// uses the downloaded-only filter to show only local models (see LMStudioClient.fetchModels).
    case exo
    /// Raw value kept as "openRouter" so existing SwiftData records deserialise correctly.
    case cloudAPI = "openRouter"
    /// Dedicated OpenRouter endpoint — fixed base URL, user supplies only the API key.
    case openRouter = "openRouterFixed"
    /// Dedicated Nous Research endpoint — fixed base URL, user supplies only the API key.
    case nous = "nousFixed"

    /// Self-hosted servers run on your own hardware (host:port, no auth) and may expose
    /// a `modelo-tap` GPU agent. Cloud APIs (`cloudAPI`, `openRouter`, `nous`) are managed endpoints that do not.
    var isLocal: Bool {
        switch self {
        case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: true
        case .cloudAPI, .openRouter, .nous:                         false
        }
    }

    /// Human-readable runtime name for chips, menus, and labels.
    var displayName: String {
        switch self {
        case .lmStudio:   return "LM Studio"
        case .llamaCpp:   return "llama.cpp"
        case .llamaSwap:  return "llama-swap"
        case .oMLX:       return "oMLX"
        case .ollama:     return "Ollama"
        case .exo:        return "exo"
        case .cloudAPI:   return "Cloud API"
        case .openRouter: return "OpenRouter"
        case .nous:       return "Nous Research"
        }
    }

    /// Default `host:port` port for a freshly-added local server of this kind. Used to
    /// seed (and re-seed, while still at a default) the port field in Settings. Cloud
    /// kinds don't use host:port, so they report 0.
    var defaultPort: Int {
        switch self {
        case .lmStudio:                       return 1234
        case .llamaCpp:                       return 8080
        case .llamaSwap:                      return 8080
        case .oMLX:                           return 8000
        case .ollama:                         return 11434
        case .exo:                            return 52415
        case .cloudAPI, .openRouter, .nous:   return 0
        }
    }

    /// True when the base URL is hardcoded and not user-configurable.
    /// The URL field in Settings is hidden for these kinds.
    var hasFixedURL: Bool {
        switch self {
        case .openRouter, .nous: return true
        default:                 return false
        }
    }

    /// The local runtimes, in declaration order — used to populate the runtime picker.
    static var localCases: [ServerKind] { allCases.filter(\.isLocal) }

    /// True if `port` is the canonical default for some local kind — i.e. the user
    /// hasn't hand-picked it, so switching runtimes may safely re-seed it.
    static func isDefaultLocalPort(_ port: Int) -> Bool {
        localCases.contains { $0.defaultPort == port }
    }
}

/// A `Sendable` snapshot of a `Server` for the networking layer. Built on the
/// MainActor (it reads the `@Model`), then handed across actor boundaries safely.
struct Endpoint: Sendable, Equatable {
    let baseURL: String
    let kind: ServerKind
    /// nil for LM Studio (no auth); bearer token for cloud API endpoints.
    let apiKey: String?
}

extension Endpoint {
    /// Hardcoded base URL for the dedicated OpenRouter endpoint.
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    /// Hardcoded base URL for the dedicated Nous Research endpoint.
    static let nousBaseURL = "https://inference-api.nousresearch.com/v1"

    /// Keychain account key for a server's bearer token (cloud APIs, the dedicated
    /// OpenRouter endpoint, or a local OpenAI-compatible server that requires auth, e.g. an MLX server).
    static func keychainAccount(for server: Server) -> String { "openrouter:\(server.id)" }

    /// Reads the server's properties + any Keychain bearer token. A token is optional
    /// for local servers (most need none) and sent only when present. Not actor-isolated:
    /// it does only synchronous reads, matching how the reachability probe touches `Server`.
    init(server: Server, keychain: KeychainStore) {
        let key = keychain.get(account: Endpoint.keychainAccount(for: server))
        self.init(baseURL: server.baseURL, kind: server.kind, apiKey: key?.isEmpty == false ? key : nil)
    }
}
