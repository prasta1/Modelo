import AppKit
import Foundation
import SwiftData

/// Polls each server's HTTP endpoint and records online/offline in the registry.
/// Cadence: 10s while a server is online, 30s while offline/unknown (so a sleeping
/// MacBook isn't hammered), and `idleInterval` (60s) for everything while Modelo
/// is in the background — nobody is looking at the status dots then, and the
/// probes keep remote servers busy for no benefit. The `probe` is injected for
/// testability; production passes a closure backed by
/// `LMStudioClient.probeReachable` (a single-shot, short-timeout check — NOT
/// fetchModels, which double-falls-back and can stall).
@Observable
@MainActor
final class ReachabilityMonitor {
    /// Backed-off probe cadence for every server kind while the app is in the background.
    static let idleInterval: Duration = .seconds(60)

    private let registry: ServerRegistry
    private let keychain: KeychainStore
    /// Takes a Sendable `Endpoint`, not the `Server` @Model: the endpoint is built
    /// from the model on the main actor (in `checkOnce`) so this closure — which
    /// runs off-main — never touches a non-Sendable SwiftData object.
    private let probe: (Endpoint) async -> Bool
    private var loops: [PersistentIdentifier: Task<Void, Never>] = [:]
    /// Last `start(servers:)` argument, kept so a foreground change can restart
    /// the loops without the caller re-supplying it.
    private var servers: [Server] = []
    private var isForeground = true

    init(registry: ServerRegistry, keychain: KeychainStore = KeychainStore(),
         probe: @escaping (Endpoint) async -> Bool) {
        self.registry = registry
        self.keychain = keychain
        self.probe = probe
        observeAppActivation()
    }

    /// Pure policy: how long to wait before the next probe.
    /// Cloud APIs use a fixed cadence (no sleep state); local servers back off when
    /// offline; everything backs off to `idleInterval` while the app is in the background.
    func pollInterval(for status: ServerStatus, kind: ServerKind, foreground: Bool = true) -> Duration {
        guard foreground else { return Self.idleInterval }
        switch kind {
        case .cloudAPI, .openRouter, .nous: return .seconds(30)
        case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: return status == .online ? .seconds(10) : .seconds(30)
        }
    }

    /// One probe + status write. Used by tests and by the running loop.
    func checkOnce(_ server: Server) async {
        // Build the Sendable Endpoint snapshot off the @Model here, on the main
        // actor, before handing it to the off-main probe.
        let endpoint = Endpoint(server: server, keychain: keychain)

        // Cloud servers (OpenRouter, custom cloud APIs) with no API key are
        // reachable but unusable for chat — mark them distinctly so the UI
        // can prompt the user to add a key instead of showing a misleading green dot.
        if !server.kind.isLocal, endpoint.apiKey == nil {
            registry.setStatus(.needsKey, for: server)
            registry.setLatency(nil, for: server)
            return
        }

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
        self.servers = servers
        restartLoops()
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
    }

    /// App activate/deactivate hook. Returning to the foreground restarts the
    /// loops so each server is probed immediately (statuses may be up to
    /// `idleInterval` stale); going background just flips the cadence — each
    /// loop picks up the longer sleep on its next cycle.
    func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        // Restart only when loops are live: don't resurrect an explicit stop().
        if foreground && !loops.isEmpty { restartLoops() }
    }

    private func observeAppActivation() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(false) }
        }
    }

    private func restartLoops() {
        stop()
        for server in servers {
            loops[server.persistentModelID] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.checkOnce(server)
                    let interval = self.pollInterval(for: self.registry.status(for: server),
                                                     kind: server.kind,
                                                     foreground: self.isForeground)
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }
}
