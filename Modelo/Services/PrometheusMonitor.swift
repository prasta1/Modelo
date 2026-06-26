import Foundation
import SwiftUI

/// Polls each local server's Prometheus `/metrics` endpoint and publishes the latest
/// `PrometheusSnapshot` (§2.3). Mirrors `GPUMonitor`: one cancellable `Task` per
/// server, `@MainActor` state, `start(servers:)` / `stop()`. Only local servers with
/// a non-empty `prometheusURL` are polled.
@Observable
@MainActor
final class PrometheusMonitor {
    private(set) var snapshots: [UUID: PrometheusSnapshot] = [:]

    private var loops: [UUID: Task<Void, Never>] = [:]
    private let session: URLSession
    private let interval: Duration

    init(session: URLSession = PrometheusMonitor.defaultSession(), interval: Duration = .seconds(3)) {
        self.session = session
        self.interval = interval
    }

    nonisolated static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func snapshot(for server: Server) -> PrometheusSnapshot? { snapshots[server.id] }

    /// (Re)start polling for the given servers. Cancels any previous loops first.
    func start(servers: [Server]) {
        stop()
        for server in servers where server.kind.isLocal {
            guard let raw = server.prometheusURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let id = server.id
            loops[id] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.poll(id: id, url: raw)
                    try? await Task.sleep(for: self.interval)
                }
            }
        }
    }

    func stop() {
        for task in loops.values { task.cancel() }
        loops.removeAll()
    }

    private func poll(id: UUID, url: String) async {
        guard let u = URL(string: url) else { return }
        guard let (data, response) = try? await session.data(from: u),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return }
        snapshots[id] = PrometheusSnapshot(samples: PrometheusParser.parse(text))
    }
}
