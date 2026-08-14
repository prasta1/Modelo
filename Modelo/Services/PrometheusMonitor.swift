import Foundation
import SwiftUI

/// Polls each local server's Prometheus `/metrics` endpoint and publishes the latest
/// `PrometheusSnapshot` (§2.3). Only local servers with a non-empty `prometheusURL` are polled.
@Observable
@MainActor
final class PrometheusMonitor {
    private(set) var snapshots: [UUID: PrometheusSnapshot] = [:]

    private var loop = PollingLoop<UUID>()
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

    func start(servers: [Server]) {
        let items = servers
            .filter { $0.kind.isLocal }
            .compactMap { server -> (key: UUID, tick: @MainActor @Sendable () async -> Void)? in
                guard let raw = server.prometheusURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                let id = server.id
                return (key: id, tick: { [weak self] in await self?.poll(id: id, url: raw) })
            }
        loop.start(for: items, interval: interval)
    }

    func stop() {
        loop.stop()
    }

    private func poll(id: UUID, url: String) async {
        guard let u = URL(string: url) else { return }
        guard let (data, response) = try? await session.data(from: u),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return }
        snapshots[id] = PrometheusSnapshot(samples: PrometheusParser.parse(text))
    }
}
