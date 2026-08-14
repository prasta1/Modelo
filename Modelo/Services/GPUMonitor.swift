import Foundation
import SwiftUI

/// Polls each local server's `modelo-tap` GPU agent (`GET /gpu`) and publishes the
/// latest snapshot. Only servers that are local and have a non-empty `metricsAgentURL`
/// are polled.
@Observable
@MainActor
final class GPUMonitor {
    private(set) var snapshots: [UUID: GPUSnapshot] = [:]

    private var loop = PollingLoop<UUID>()
    private var macmonTask: Task<Void, Never>?
    private var macmonProcess: Process?
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

    func start(servers: [Server]) {
        stop()
        let items = servers
            .filter { $0.kind.isLocal }
            .compactMap { server -> (key: UUID, tick: @MainActor @Sendable () async -> Void)? in
                guard let raw = server.metricsAgentURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                let id = server.id
                return (key: id, tick: { [weak self] in await self?.poll(id: id, agentURL: raw) })
            }
        loop.start(for: items, interval: interval)
        let macmonIDs = servers.filter { $0.kind.isLocal && $0.localGPU }.map(\.id)
        if !macmonIDs.isEmpty { startMacmon(for: macmonIDs) }
    }

    func stop() {
        loop.stop()
        macmonTask?.cancel(); macmonTask = nil
        macmonProcess?.terminate(); macmonProcess = nil
        snapshots.removeAll()
    }

    /// Streams `macmon pipe` and republishes each sample to the opted-in servers.
    private func startMacmon(for ids: [UUID]) {
        guard let path = Macmon.resolvedPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["pipe", "-i", "1500"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = nil
        do { try proc.run() } catch {
            Log.monitor.error("macmon failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        macmonProcess = proc
        macmonTask = Task { [weak self] in
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    guard let snap = Macmon.parse(line) else { continue }
                    guard let self else { break }
                    for id in ids { self.snapshots[id] = snap }
                }
            } catch {
                Log.monitor.error("macmon stream ended: \(error.localizedDescription, privacy: .public)")
                for id in ids { self?.snapshots[id] = nil }
            }
        }
    }

    private func poll(id: UUID, agentURL: String) async {
        let base = agentURL.hasSuffix("/") ? String(agentURL.dropLast()) : agentURL
        guard let url = URL(string: "\(base)/gpu") else { snapshots[id] = nil; return }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let snap = try? JSONDecoder().decode(GPUSnapshot.self, from: data) else {
            snapshots[id] = nil; return
        }
        snapshots[id] = snap
    }
}
