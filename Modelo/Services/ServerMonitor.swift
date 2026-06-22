import Foundation

/// A point-in-time view of the models an LM Studio server currently has loaded.
struct ModelSnapshot: Equatable {
    let models: [LMStudioModel]
}

/// Polls each online LM Studio server's `/api/v0/models` every 3 seconds and
/// stores the currently-loaded model per server. Injected as an `@Environment`
/// value; the inspector and status views read from it without triggering network
/// calls themselves.
@Observable
@MainActor
final class ServerMonitor {
    private(set) var snapshots: [UUID: ModelSnapshot] = [:]

    private var loops: [UUID: Task<Void, Never>] = [:]
    private let client: any ChatProvider

    init(client: any ChatProvider = LMStudioClient.shared) {
        self.client = client
    }

    /// The loaded model snapshot for `server`, or nil if none is known yet.
    func snapshot(for server: Server) -> ModelSnapshot? { snapshots[server.id] }

    /// Starts a 3-second poll loop per LM Studio server. Restarts cleanly if called again.
    func start(servers: [Server], registry: ServerRegistry) {
        stop()
        for server in servers where server.kind == .lmStudio {
            loops[server.id] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    if registry.isOnline(server) {
                        await self.poll(server)
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
    }

    /// Fetches the model list and stores whichever one reports `state == "loaded"`.
    /// Falls back to the first model in the list when no state is reported (v1/models).
    func poll(_ server: Server) async {
        let endpoint = Endpoint(baseURL: server.baseURL, kind: .lmStudio, apiKey: nil)
        guard let models = try? await client.fetchModels(endpoint: endpoint) else { return }
        let loaded = models.filter { $0.isLoaded }
        // Fall back to the first model when none report a loaded state (older /v1/models endpoint).
        let toStore = loaded.isEmpty ? [models.first].compactMap { $0 } : loaded
        if !toStore.isEmpty {
            snapshots[server.id] = ModelSnapshot(models: toStore)
        }
    }
}
