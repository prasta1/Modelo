import Foundation
import SwiftData

/// A registered chat endpoint. LM Studio machines are seeded on first launch;
/// additional cloud API endpoints can be added in Settings.
@Model
final class Server {
    var id: UUID = UUID()
    var label: String = ""
    /// LM Studio: hostname or IP (e.g. "localhost"). Cloud API: the full base URL
    /// (e.g. "https://api.together.xyz/v1"). Repurposed per kind to avoid a migration.
    var host: String = ""
    /// LM Studio server port (default 1234). Unused for cloud API endpoints.
    var port: Int = 1234
    /// Sort position in the sidebar.
    var sortOrder: Int = 0
    /// Backend kind (raw-string-backed for a simple SwiftData schema).
    var kindRaw: String = ServerKind.lmStudio.rawValue
    /// DEPRECATED: never used; secrets now live in Keychain (`KeychainStore`). Kept to avoid a migration.
    var apiKey: String?

    var kind: ServerKind {
        get { ServerKind(rawValue: kindRaw) ?? .lmStudio }
        set { kindRaw = newValue.rawValue }
    }

    /// Base URL used by the networking layer.
    /// - LM Studio: `http://host:port`.
    /// - Cloud API: the value stored in `host` (the user's full base URL, e.g. `https://api.together.xyz/v1`).
    var baseURL: String {
        switch kind {
        case .lmStudio:   "http://\(Server.normalizedHost(host)):\(port)"
        case .cloudAPI:   host
        case .openRouter: Endpoint.openRouterBaseURL
        }
    }

    /// Cleans a user-entered LM Studio host so it can be safely interpolated into
    /// `http://<host>:<port>`.
    ///
    /// Without this, a host that already carries a scheme (e.g. `http://localhost`)
    /// produced a doubled-up `http://http://localhost:1234` — an invalid string that
    /// makes `URL(string:)` return nil, so the reachability probe silently failed and
    /// the server read as permanently offline. We strip the scheme, surrounding
    /// whitespace, and any trailing slash so the bare host remains.
    /// - Parameter raw: The host string as typed by the user.
    /// - Returns: A bare host with no scheme, whitespace, or trailing slash.
    static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading http:// or https:// (case-insensitive).
        if let schemeRange = host.range(of: "^https?://",
                                        options: [.regularExpression, .caseInsensitive]) {
            host.removeSubrange(schemeRange)
        }
        // Drop any trailing slash(es) left behind (e.g. "localhost/").
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    init(label: String, host: String, port: Int = 1234, sortOrder: Int = 0,
         kind: ServerKind = .lmStudio) {
        self.label = label
        self.host = host
        self.port = port
        self.sortOrder = sortOrder
        self.kindRaw = kind.rawValue
    }
}
