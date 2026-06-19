import Foundation
import SwiftData

/// Reachability state for a server.
enum ServerStatus: Equatable { case unknown, online, offline }

/// Holds live reachability status per server (keyed by `Server.id`) and seeds
/// the two known machines on first launch. The persisted `Server` rows live in
/// SwiftData; this object only tracks transient status used for routing + the UI dot.
@Observable
@MainActor
final class ServerRegistry {
    private(set) var statuses: [UUID: ServerStatus] = [:]

    func status(for server: Server) -> ServerStatus { statuses[server.id] ?? .unknown }
    func isOnline(_ server: Server) -> Bool { status(for: server) == .online }

    func setStatus(_ status: ServerStatus, for server: Server) {
        statuses[server.id] = status
    }

    /// Seeds one generic local server + OpenRouter on first launch. Idempotent.
    /// Users configure their own host/label in Settings.
    func seedIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        guard existing.isEmpty else { return }
        context.insert(Server(label: "Mac Studio", host: "studio", port: 1234, sortOrder: 0))
        // Cloud endpoint: seeded but inert until an API key is set in Settings (Keychain).
        context.insert(Server(label: "OpenRouter", host: "", port: 0, sortOrder: 1, kind: .openRouter))
        do { try context.save() }
        catch { print("ServerRegistry.seedIfNeeded save failed: \(error)") }
    }
}
