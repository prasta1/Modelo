import Foundation
import SwiftData
import SwiftUI

/// Editable form state for adding or editing an endpoint. Nothing is persisted until
/// `save(into:keychain:existing:)`, so cancelling a form never leaves a half-made row.
struct EndpointDraft: Equatable {
    var kind: ServerKind
    var label: String
    /// Local runtimes: hostname or IP (optionally `https://`). `.cloudAPI`: the full base URL.
    /// Unused for fixed-URL kinds.
    var host: String
    var port: Int
    var connectionID: String
    /// Bearer token for cloud kinds; stored only in the keychain.
    var apiKey: String

    /// A blank draft for `kind`, pre-filled with its default port and display name.
    init(kind: ServerKind) {
        self.kind = kind
        label = kind == .cloudAPI ? "Cloud API" : kind.displayName
        host = ""
        port = kind.defaultPort
        connectionID = ""
        apiKey = ""
    }

    /// A custom cloud endpoint pre-filled from a one-click provider preset.
    init(preset: CloudPreset) {
        self.init(kind: .cloudAPI)
        label = preset.name
        host = preset.baseURL
    }

    /// A draft holding `server`'s current values, including its keychain secret.
    init(server: Server, keychain: KeychainStore) {
        kind = server.kind
        label = server.label
        host = server.host
        port = server.port
        connectionID = server.connectionID
        apiKey = keychain.get(account: Endpoint.keychainAccount(for: server)) ?? ""
    }

    /// Changes the local runtime. The port and label follow the new runtime only while
    /// they're still the old defaults, so a hand-picked port or name survives.
    mutating func switchRuntime(to newKind: ServerKind) {
        if ServerKind.isDefaultLocalPort(port) { port = newKind.defaultPort }
        if label == kind.displayName { label = newKind.displayName }
        kind = newKind
    }

    /// True when the fields describe an endpoint worth saving or probing.
    var isValid: Bool {
        guard !trimmed(label).isEmpty else { return false }
        if kind.isLocal {
            let bare = normalizedHost.replacingOccurrences(of: "https://", with: "")
            return !bare.isEmpty && (1...65535).contains(port)
        }
        if kind.hasFixedURL { return true }
        guard let url = URL(string: trimmed(host)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        return url.host() != nil
    }

    /// A Sendable endpoint for these unsaved values, for "Test connection".
    var endpoint: Endpoint {
        let key = trimmed(apiKey)
        return Endpoint(baseURL: Server.baseURL(kind: kind, host: storedHost, port: port),
                        kind: kind, apiKey: key.isEmpty ? nil : key)
    }

    /// Inserts a new server (when `existing` is nil) or updates `existing`, writes the
    /// API key for cloud kinds to the keychain (an empty key clears it), and saves.
    /// - Returns: The saved server.
    @discardableResult
    func save(into context: ModelContext, keychain: KeychainStore, existing: Server?) -> Server {
        let server: Server
        if let existing {
            server = existing
        } else {
            // Same rule as the Mac's Settings: append after the current last row.
            let maxOrder = (try? context.fetch(FetchDescriptor<Server>()))?.map(\.sortOrder).max()
            server = Server(label: "", host: "", sortOrder: (maxOrder ?? 0) + 1, kind: kind)
            context.insert(server)
        }
        server.label = trimmed(label)
        server.kind = kind
        server.host = storedHost
        server.port = kind.isLocal ? port : 0
        server.connectionID = trimmed(connectionID)
        if !kind.isLocal {
            let key = trimmed(apiKey)
            keychain.set(key.isEmpty ? nil : key, account: Endpoint.keychainAccount(for: server))
        }
        context.saveOrLog()
        return server
    }

    private var normalizedHost: String { Server.normalizedHost(host) }

    /// The `host` value as persisted for this kind.
    private var storedHost: String {
        if kind.isLocal { return normalizedHost }
        return kind.hasFixedURL ? "" : trimmed(host)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// List-level edits to the endpoints list.
enum ServerListActions {
    /// Deletes `server` and its keychain secret, so no orphaned API key is left behind.
    static func delete(_ server: Server, in context: ModelContext, keychain: KeychainStore) {
        keychain.set(nil, account: Endpoint.keychainAccount(for: server))
        context.delete(server)
        context.saveOrLog()
    }

    /// Applies a drag-to-reorder and rewrites `sortOrder` as 0-based contiguous
    /// positions. The caller saves.
    static func reorder(_ servers: [Server], fromOffsets: IndexSet, toOffset: Int) {
        var ordered = servers
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, server) in ordered.enumerated() { server.sortOrder = index }
    }
}
