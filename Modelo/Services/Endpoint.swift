import Foundation
import SwiftData

/// Which kind of backend a `Server` row points at.
/// - `lmStudio`: a local LM Studio machine (host:port over HTTP, no auth, rich `/api/v0`).
/// - `llamaCpp`: a local llama.cpp server, often fronted by llama-swap
///   (host:port over HTTP, OpenAI-compatible `/v1`, optional auth, no `/api/v0`).
/// - `oMLX`: a local oMLX server (omlx.ai) — an Apple-silicon MLX runtime. Same wire
///   shape as `llamaCpp` (host:port, OpenAI-compatible `/v1`); distinct only in label/port.
/// - `cloudAPI`: any OpenAI-compatible cloud endpoint (user-supplied HTTPS base URL, bearer auth).
/// - `openRouter`: hardcoded OpenRouter cloud endpoint — user supplies only the API key.
///
/// `lmStudio`, `llamaCpp`, and `oMLX` are *local* (self-hosted) — they run on hardware you
/// control and can have a `modelo-tap` GPU agent next to them. Add new local runtimes
/// (vLLM, sglang, …) as cases here; everything but LM Studio's `/api/v0` is generic local.
enum ServerKind: String, Codable, Sendable, CaseIterable {
    case lmStudio
    /// Raw value kept as "llamaSwap" so servers saved before the rename still deserialise.
    case llamaCpp = "llamaSwap"
    case oMLX
    /// Raw value kept as "openRouter" so existing SwiftData records deserialise correctly.
    case cloudAPI = "openRouter"
    /// Dedicated OpenRouter endpoint — fixed base URL, user supplies only the API key.
    case openRouter = "openRouterFixed"

    /// Self-hosted servers run on your own hardware (host:port, no auth) and may expose
    /// a `modelo-tap` GPU agent. Cloud APIs (`cloudAPI`, `openRouter`) are managed endpoints that do not.
    var isLocal: Bool {
        switch self {
        case .lmStudio, .llamaCpp, .oMLX: true
        case .cloudAPI, .openRouter:      false
        }
    }

    /// Human-readable runtime name for chips, menus, and labels.
    var displayName: String {
        switch self {
        case .lmStudio:   return "LM Studio"
        case .llamaCpp:   return "llama.cpp"
        case .oMLX:       return "oMLX"
        case .cloudAPI:   return "Cloud API"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Default `host:port` port for a freshly-added local server of this kind. Used to
    /// seed (and re-seed, while still at a default) the port field in Settings. Cloud
    /// kinds don't use host:port, so they report 0.
    var defaultPort: Int {
        switch self {
        case .lmStudio:              return 1234
        case .llamaCpp:              return 8080
        case .oMLX:                  return 8000
        case .cloudAPI, .openRouter: return 0
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
