import Foundation
import SwiftData

/// Which kind of backend a `Server` row points at.
/// - `lmStudio`: a local LM Studio machine (host:port over HTTP, no auth).
/// - `cloudAPI`: any OpenAI-compatible cloud endpoint (user-supplied HTTPS base URL, bearer auth).
/// - `openRouter`: hardcoded OpenRouter cloud endpoint — user supplies only the API key.
enum ServerKind: String, Codable, Sendable {
    case lmStudio
    /// Raw value kept as "openRouter" so existing SwiftData records deserialise correctly.
    case cloudAPI = "openRouter"
    case openRouter = "openRouterFixed"
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

    /// Keychain account key for a cloud API server's bearer token.
    static func keychainAccount(for server: Server) -> String { "openrouter:\(server.id)" }

    /// Reads the server's properties + (for cloud endpoints) its Keychain key. Not actor-isolated:
    /// it does only synchronous reads, matching how the reachability probe already touches `Server`.
    init(server: Server, keychain: KeychainStore) {
        let key = server.kind != .lmStudio
            ? keychain.get(account: Endpoint.keychainAccount(for: server))
            : nil
        self.init(baseURL: server.baseURL, kind: server.kind, apiKey: key)
    }
}
