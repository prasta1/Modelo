import Foundation

/// Polls each server's HTTP endpoint and records online/offline in the registry.
/// Cadence: 10s while a server is online, 30s while offline/unknown (so a sleeping
/// MacBook isn't hammered). The `probe` is injected for testability; production
/// passes a closure backed by `LMStudioClient.probeReachable` (a single-shot,
/// short-timeout check — NOT fetchModels, which double-falls-back and can stall).
@Observable
@MainActor
final class ReachabilityMonitor {
    private let registry: ServerRegistry
    private let keychain: KeychainStore
    /// Takes a Sendable `Endpoint`, not the `Server` @Model: the endpoint is built
    /// from the model on the main actor (in `checkOnce`) so this closure — which
    /// runs off-main — never touches a non-Sendable SwiftData object.
    private let probe: (Endpoint) async -> Bool
    private var loops: [UUID: Task<Void, Never>] = [:]

    init(registry: ServerRegistry, keychain: KeychainStore = KeychainStore(),
         probe: @escaping (Endpoint) async -> Bool) {
        self.registry = registry
        self.keychain = keychain
        self.probe = probe
    }

    /// Pure policy: how long to wait before the next probe.
    /// Cloud APIs use a fixed cadence (no sleep state); local servers back off when offline.
    func pollInterval(for status: ServerStatus, kind: ServerKind) -> Duration {
        switch kind {
        case .cloudAPI: return .seconds(30)
        case .lmStudio, .llamaSwap: return status == .online ? .seconds(10) : .seconds(30)
        }
    }

    /// One probe + status write. Used by tests and by the running loop.
    func checkOnce(_ server: Server) async {
        // Build the Sendable Endpoint snapshot off the @Model here, on the main
        // actor, before handing it to the off-main probe.
        let endpoint = Endpoint(server: server, keychain: keychain)
        // Time the probe round-trip for the Status dashboard's latency tile. The
        // probe is a single short HTTP request, so wall-clock around the await is
        // a good proxy for endpoint latency.
        let start = Date()
        let ok = await probe(endpoint)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        registry.setStatus(ok ? .online : .offline, for: server)
        registry.setLatency(ok ? elapsedMs : nil, for: server)
    }

    /// Starts a polling loop per server. Cancels any previous loops first.
    func start(servers: [Server]) {
        stop()
        for server in servers {
            loops[server.id] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.checkOnce(server)
                    let interval = self.pollInterval(for: self.registry.status(for: server),
                                                     kind: server.kind)
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
    }
}
