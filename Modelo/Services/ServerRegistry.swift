import Foundation
import SwiftData

/// Reachability state for a server.
enum ServerStatus: Equatable {
    case unknown, online, offline, needsKey

    /// Short uppercase badge text shown next to the status LED.
    var displayLabel: String {
        switch self {
        case .online:   "LIVE"
        case .offline:  "OFFLINE"
        case .unknown:  "PROBING"
        case .needsKey: "NO KEY"
        }
    }
}

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
        catch { Log.data.error("seedIfNeeded save failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Adds the "Apple Intelligence" server once, on Macs that can run it. A
    /// `UserDefaults` flag (not the row's presence) records that it happened, so a
    /// row the user deleted stays deleted; hiding it is the per-server toggle.
    /// The flag is only set when a row is actually added, so a Mac that becomes
    /// eligible later (e.g. after an OS upgrade) still gets it.
    /// - Parameters:
    ///   - isEligible: `AppleIntelligenceClient.isEligible()` in the app; injected for tests.
    ///   - defaults: Where the once-only flag lives.
    func seedAppleIntelligenceIfNeeded(in context: ModelContext, isEligible: Bool,
                                       defaults: UserDefaults = .standard) {
        let key = "didSeedAppleIntelligence"
        guard isEligible, !defaults.bool(forKey: key) else { return }
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        context.insert(Server(label: "Apple Intelligence", host: "", port: 0,
                              sortOrder: nextOrder, kind: .appleIntelligence))
        do {
            try context.save()
            defaults.set(true, forKey: key)
        } catch {
            Log.data.error("seedAppleIntelligenceIfNeeded save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
