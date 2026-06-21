import Foundation
import SwiftUI

/// Polls each local server's `modelo-tap` GPU agent (`GET /gpu`) and publishes the
/// latest snapshot.
///
/// Mirrors `ServerMonitor`'s shape: one cancellable polling `Task` per server,
/// `@MainActor`-isolated state, and a `start(servers:)` / `stop()` lifecycle.
/// Only servers that are local *and* have a non-empty `metricsAgentURL` are polled.
@Observable
@MainActor
final class GPUMonitor {
    private(set) var snapshots: [UUID: GPUSnapshot] = [:]

    private var loops: [UUID: Task<Void, Never>] = [:]
    private let session: URLSession
    private let interval: Duration

    init(session: URLSession = GPUMonitor.defaultSession(), interval: Duration = .seconds(2)) {
        self.session = session
        self.interval = interval
    }

    nonisolated static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func snapshot(for server: Server) -> GPUSnapshot? { snapshots[server.id] }

    /// (Re)start polling for the given servers. Cancels any previous loops first.
    func start(servers: [Server]) {
        stop()
        for server in servers where server.kind.isLocal {
            guard let raw = server.metricsAgentURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let id = server.id
            loops[id] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.poll(id: id, agentURL: raw)
                    try? await Task.sleep(for: self.interval)
                }
            }
        }
    }

    func stop() {
        for task in loops.values { task.cancel() }
        loops.removeAll()
    }

    private func poll(id: UUID, agentURL: String) async {
        let base = agentURL.hasSuffix("/") ? String(agentURL.dropLast()) : agentURL
        guard let url = URL(string: "\(base)/gpu") else { return }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let snap = try? JSONDecoder().decode(GPUSnapshot.self, from: data) else { return }
        snapshots[id] = snap
    }
}
