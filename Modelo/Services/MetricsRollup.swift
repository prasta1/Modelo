import Foundation

/// A point-in-time summary of inference performance derived from recent UsageRecords.
/// Pure value type — no I/O, fully testable. Nil stats mean no data exists yet.
struct InferenceRollup {
    let requestCount: Int

    // Decode speed (tok/s)
    let lastTokPerSec: Double?
    let avgTokPerSec: Double?
    let peakTokPerSec: Double?

    // Time-to-first-token
    let lastTTFTms: Int?
    let avgTTFTms: Double?
    let peakTTFTms: Int?

    // Last-turn token counts
    let lastPromptTokens: Int?
    let lastCompletionTokens: Int?

    // Chart series — ordered oldest → newest for left-to-right chart rendering
    let tokPerSecHistory: [Double]
    let ttftHistory: [Double]

    static let empty = InferenceRollup(
        requestCount: 0,
        lastTokPerSec: nil, avgTokPerSec: nil, peakTokPerSec: nil,
        lastTTFTms: nil, avgTTFTms: nil, peakTTFTms: nil,
        lastPromptTokens: nil, lastCompletionTokens: nil,
        tokPerSecHistory: [], ttftHistory: []
    )

    /// Computes rollup from the `limit` most recent records for a given server.
    /// Pass records pre-filtered by server in any order — sorted internally.
    static func compute(from records: [UsageRecord], limit: Int = 20) -> InferenceRollup {
        guard !records.isEmpty else { return .empty }

        // Most recent `limit`, then reversed so index 0 = oldest (chart left edge)
        let recent = Array(
            records.sorted { $0.timestamp > $1.timestamp }.prefix(limit).reversed()
        )
        let count = recent.count
        let tpsValues = recent.map { $0.tokensPerSecond }
        let ttftValues = recent.map { $0.ttftMillis }
        let last = recent.last!

        let avgTps = tpsValues.reduce(0, +) / Double(count)
        let peakTps = tpsValues.max()!
        let avgTtft = Double(ttftValues.reduce(0, +)) / Double(count)
        let peakTtft = ttftValues.max()!

        return InferenceRollup(
            requestCount: count,
            lastTokPerSec: last.tokensPerSecond,
            avgTokPerSec: avgTps,
            peakTokPerSec: peakTps,
            lastTTFTms: last.ttftMillis,
            avgTTFTms: avgTtft,
            peakTTFTms: peakTtft,
            lastPromptTokens: last.promptTokens,
            lastCompletionTokens: last.completionTokens,
            tokPerSecHistory: tpsValues,
            ttftHistory: ttftValues.map(Double.init)
        )
    }
}
