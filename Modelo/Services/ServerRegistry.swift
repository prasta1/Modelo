import Foundation
import SwiftData

/// Reachability state for a server.
enum ServerStatus: Equatable { case unknown, online, offline }

/// Holds live reachability status per server (keyed by `Server.persistentModelID`) and seeds
/// the two known machines on first launch. The persisted `Server` rows live in
/// SwiftData; this object only tracks transient status used for routing + the UI dot.
@Observable
@MainActor
final class ServerRegistry {
    private(set) var statuses: [PersistentIdentifier: ServerStatus] = [:]
    /// Last successful reachability-probe round-trip per server, in milliseconds.
    /// Only set while a server is online; cleared when it goes offline.
    private(set) var latencies: [PersistentIdentifier: Double] = [:]

    func status(for server: Server) -> ServerStatus { statuses[server.persistentModelID] ?? .unknown }
    func isOnline(_ server: Server) -> Bool { status(for: server) == .online }
    func latency(for server: Server) -> Double? { latencies[server.persistentModelID] }

    func setStatus(_ status: ServerStatus, for server: Server) {
        statuses[server.persistentModelID] = status
    }

    /// Records (or clears, with nil) a server's last probe latency in milliseconds.
    func setLatency(_ ms: Double?, for server: Server) {
        latencies[server.persistentModelID] = ms
    }

    /// Seeds one generic local server on first launch. Idempotent.
    /// Cloud API endpoints are added by the user in Settings → Cloud APIs.
    func seedIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        guard existing.isEmpty else { return }
        context.insert(Server(label: "Local Server", host: "localhost", port: 1234, sortOrder: 0))
        do { try context.save() }
        catch { print("ServerRegistry.seedIfNeeded save failed: \(error)") }
    }
}
