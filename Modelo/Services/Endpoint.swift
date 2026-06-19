import Foundation
import SwiftData

/// Which kind of backend a `Server` row points at.
/// - `lmStudio`: a local LM Studio machine (host:port over HTTP, no auth).
/// - `openRouter`: the OpenRouter cloud API (fixed HTTPS base, bearer auth).
enum ServerKind: String, Codable, Sendable {
    case lmStudio
    case openRouter
}

/// A `Sendable` snapshot of a `Server` for the networking layer. Built on the
/// MainActor (it reads the `@Model`), then handed across actor boundaries safely.
struct Endpoint: Sendable, Equatable {
    let baseURL: String
    let kind: ServerKind
    /// nil for keyless LM Studio; the bearer token for OpenRouter.
    let apiKey: String?
}

extension Endpoint {
    /// Keychain account under which an OpenRouter server's key is stored.
    static func keychainAccount(for server: Server) -> String { "openrouter:\(server.id)" }

    /// Reads the server's properties + (for OpenRouter) its Keychain key. Not actor-isolated:
    /// it does only synchronous reads, matching how the reachability probe already touches `Server`.
    init(server: Server, keychain: KeychainStore) {
        let key = server.kind == .openRouter
            ? keychain.get(account: Endpoint.keychainAccount(for: server))
            : nil
        self.init(baseURL: server.baseURL, kind: server.kind, apiKey: key)
    }
}
