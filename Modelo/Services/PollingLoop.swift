import Foundation

/// Manages a keyed set of per-server polling tasks, eliminating the boilerplate
/// `[ID: Task]` dict, `stop()`, and `while !Task.isCancelled` loop shared by
/// ServerMonitor, ReachabilityMonitor, GPUMonitor, and PrometheusMonitor.
struct PollingLoop<ID: Hashable> {
    private var tasks: [ID: Task<Void, Never>] = [:]

    var isRunning: Bool { !tasks.isEmpty }

    /// Spawns one polling task per item with a fixed inter-poll sleep interval.
    mutating func start(for items: [(key: ID, tick: @Sendable () async -> Void)],
                        interval: Duration) {
        stop()
        for (key, tick) in items {
            tasks[key] = Task {
                while !Task.isCancelled {
                    await tick()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    /// Spawns one polling task per item where each tick returns the next sleep interval.
    /// Use when cadence varies per iteration (e.g. online/offline backoff, foreground/background).
    mutating func start(for items: [(key: ID, tick: @MainActor @Sendable () async -> Duration)]) {
        stop()
        for (key, tick) in items {
            tasks[key] = Task {
                while !Task.isCancelled {
                    let interval = await tick()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    mutating func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
