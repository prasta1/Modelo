import Foundation

/// Percentile helpers for benchmark reports (§2.5).
enum Percentile {
    /// Linear-interpolated percentile, `p` in 0…1. Returns 0 for an empty input.
    static func value(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        // Single-element inputs fall out correctly: rank = 0, lo = hi = 0 → s[0].
        let rank = max(0, min(1, p)) * Double(s.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }
}

/// One request's measured outcome during a benchmark run.
struct BenchmarkResult: Sendable {
    let success: Bool
    let ttft: Double          // seconds to first token
    let tokensPerSec: Double  // decode rate (completion tokens ÷ time since first token)
}

/// Aggregated benchmark report: success/error counts, wall time, and p50/p95 of
/// time-to-first-token and decode rate across the successful requests.
struct BenchmarkReport: Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int
    let wallSeconds: Double
    let ttftP50: Double
    let ttftP95: Double
    let tpsP50: Double
    let tpsP95: Double

    init(results: [BenchmarkResult], wallSeconds: Double) {
        total = results.count
        let ok = results.filter(\.success)
        succeeded = ok.count
        failed = total - ok.count
        self.wallSeconds = wallSeconds
        let ttfts = ok.map(\.ttft)
        let tpss = ok.map(\.tokensPerSec)
        ttftP50 = Percentile.value(ttfts, 0.5)
        ttftP95 = Percentile.value(ttfts, 0.95)
        tpsP50 = Percentile.value(tpss, 0.5)
        tpsP95 = Percentile.value(tpss, 0.95)
    }
}

/// Fires N identical requests at a chosen concurrency against an endpoint and reports
/// latency/throughput percentiles (§2.5). Reuses the app's `ChatProvider`; observe
/// `isRunning`/`completed`/`report` to drive the UI.
@Observable
@MainActor
final class BenchmarkRunner {
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var report: BenchmarkReport?

    private let client: any ChatProvider
    private var task: Task<Void, Never>?

    init(client: any ChatProvider = LMStudioClient.shared) {
        self.client = client
    }

    /// Runs `requests` total at up to `concurrency` in flight. Idempotent-cancel: a
    /// second call cancels the previous run first.
    func run(endpoint: Endpoint, modelID: String, prompt: String,
             requests: Int, concurrency: Int) {
        task?.cancel()
        let total = max(1, requests)
        let inFlight = max(1, min(concurrency, total))
        report = nil
        completed = 0
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            var results: [BenchmarkResult] = []
            var launched = 0

            await withTaskGroup(of: BenchmarkResult.self) { group in
                // Prime up to `inFlight` requests, then top up as each completes.
                for _ in 0..<inFlight where launched < total {
                    launched += 1
                    group.addTask { await self.oneRequest(endpoint: endpoint, modelID: modelID, prompt: prompt) }
                }
                while let result = await group.next() {
                    results.append(result)
                    self.completed = results.count
                    if launched < total, !Task.isCancelled {
                        launched += 1
                        group.addTask { await self.oneRequest(endpoint: endpoint, modelID: modelID, prompt: prompt) }
                    }
                }
            }

            self.report = BenchmarkReport(results: results, wallSeconds: Date().timeIntervalSince(start))
            self.isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Issues one streamed request and measures TTFT + decode rate.
    private func oneRequest(endpoint: Endpoint, modelID: String, prompt: String) async -> BenchmarkResult {
        let start = Date()
        var firstToken: Date?
        var completion = 0
        do {
            // Transient prompt — never persisted, just fed to the model.
            let msg = Message(role: .user, content: prompt)
            let stream = client.streamChat(endpoint: endpoint, modelID: modelID,
                                           messages: [msg], systemPrompt: "",
                                           sampling: SamplingParams(), tools: nil)
            for try await event in stream {
                switch event {
                case .delta: if firstToken == nil { firstToken = Date() }
                case .usage(_, let c): completion = c
                case .toolCalls: break
                }
            }
        } catch {
            return BenchmarkResult(success: false, ttft: 0, tokensPerSec: 0)
        }
        let now = Date()
        let ttft = (firstToken ?? now).timeIntervalSince(start)
        let decodeElapsed = now.timeIntervalSince(firstToken ?? start)
        let tps = decodeElapsed > 0 ? Double(completion) / decodeElapsed : 0
        return BenchmarkResult(success: true, ttft: ttft, tokensPerSec: tps)
    }
}
