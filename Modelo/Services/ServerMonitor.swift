import Foundation
import SwiftData

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
    private(set) var snapshots: [PersistentIdentifier: ModelSnapshot] = [:]

    private var loops: [PersistentIdentifier: Task<Void, Never>] = [:]
    private let client: any ChatProvider
    private let exoClient: ExoClient

    init(client: any ChatProvider = LMStudioClient.shared,
         exoClient: ExoClient = ExoClient()) {
        self.client = client
        self.exoClient = exoClient
    }

    /// The loaded model snapshot for `server`, or nil if none is known yet.
    func snapshot(for server: Server) -> ModelSnapshot? { snapshots[server.persistentModelID] }

    /// Starts a 3-second poll loop per LM Studio or exo server. Restarts cleanly if called again.
    func start(servers: [Server], registry: ServerRegistry) {
        stop()
        for server in servers where server.kind == .lmStudio || server.kind == .exo {
            loops[server.persistentModelID] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    if registry.isOnline(server) {
                        await self.poll(server)
                    } else {
                        // Clear stale snapshot so offline servers don't show models as loaded.
                        snapshots.removeValue(forKey: server.persistentModelID)
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

    /// Fetches the model list and stores whichever ones report `state == "loaded"`.
    /// Falls back to the first model only when the endpoint reports no `state` field at all
    /// (older /v1/models). Always writes the snapshot on success so stale data is cleared
    /// promptly when models are unloaded.
    func poll(_ server: Server) async {
        if server.kind == .exo {
            let endpoint = Endpoint(baseURL: server.baseURL, kind: .exo, apiKey: nil)
            guard let all = try? await client.fetchModels(endpoint: endpoint),
                  let loaded = try? await exoClient.loadedInstances(endpoint: endpoint) else { return }
            let loadedIDs = Set(loaded.map(\.modelID))
            snapshots[server.persistentModelID] = ModelSnapshot(models: all.filter { loadedIDs.contains($0.id) })
            return
        }
        let endpoint = Endpoint(baseURL: server.baseURL, kind: .lmStudio, apiKey: nil)
        guard let models = try? await client.fetchModels(endpoint: endpoint) else { return }
        let loaded = models.filter { $0.isLoaded }
        // Only fall back to the first model when NO model reports a state field at all —
        // that indicates the older /v1/models endpoint. If any model has an explicit state,
        // trust it and don't promote an unloaded model as loaded.
        let anyHasState = models.contains { $0.state != nil }
        let toStore = (!anyHasState && loaded.isEmpty) ? [models.first].compactMap { $0 } : loaded
        // Always write the snapshot — even when empty — so unloaded models are cleared promptly.
        snapshots[server.persistentModelID] = ModelSnapshot(models: toStore)
    }
}
