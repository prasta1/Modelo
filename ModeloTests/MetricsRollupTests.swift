import Testing
import Foundation
@testable import Modelo

@Suite("InferenceRollup")
struct MetricsRollupTests {

    private func record(tps: Double, ttft: Int, prompt: Int = 10, completion: Int = 50,
                        secondsAgo: Double = 0) -> UsageRecord {
        let r = UsageRecord(modelID: "test", serverLabel: "Studio",
                            promptTokens: prompt, completionTokens: completion,
                            tokensPerSecond: tps, ttftMillis: ttft)
        r.timestamp = Date(timeIntervalSinceNow: -secondsAgo)
        return r
    }

    @Test func emptyInput() {
        let rollup = InferenceRollup.compute(from: [])
        #expect(rollup.requestCount == 0)
        #expect(rollup.lastTokPerSec == nil)
        #expect(rollup.tokPerSecHistory.isEmpty)
        #expect(rollup.ttftHistory.isEmpty)
    }

    @Test func singleRecord() {
        let r = record(tps: 100, ttft: 250)
        let rollup = InferenceRollup.compute(from: [r])
        #expect(rollup.requestCount == 1)
        #expect(rollup.lastTokPerSec == 100)
        #expect(rollup.avgTokPerSec == 100)
        #expect(rollup.peakTokPerSec == 100)
        #expect(rollup.lastTTFTms == 250)
        #expect(rollup.peakTTFTms == 250)
    }

    @Test func peakAndAvgComputedCorrectly() {
        let records = [
            record(tps: 60,  ttft: 300, secondsAgo: 20),
            record(tps: 90,  ttft: 200, secondsAgo: 10),
            record(tps: 120, ttft: 150, secondsAgo:  0),
        ]
        let rollup = InferenceRollup.compute(from: records)
        #expect(rollup.peakTokPerSec == 120)
        #expect(rollup.avgTokPerSec == 90)
        #expect(rollup.lastTokPerSec == 120)  // most recent
        #expect(rollup.peakTTFTms == 300)
        #expect(rollup.lastTTFTms == 150)     // most recent
    }

    @Test func limitCapsAt20Records() {
        // 25 records with distinct timestamps (oldest first = highest secondsAgo)
        let records = (1...25).map { i in record(tps: Double(i), ttft: i, secondsAgo: Double(25 - i)) }
        let rollup = InferenceRollup.compute(from: records)
        #expect(rollup.requestCount == 20)
        #expect(rollup.tokPerSecHistory.count == 20)
        #expect(rollup.ttftHistory.count == 20)
    }

    @Test func chartHistoryOrderedOldestFirst() {
        let early = record(tps: 50,  ttft: 300, secondsAgo: 60)
        let later = record(tps: 150, ttft: 100, secondsAgo:  0)
        let rollup = InferenceRollup.compute(from: [later, early])  // passed desc
        #expect(rollup.tokPerSecHistory.first == 50)   // oldest
        #expect(rollup.tokPerSecHistory.last  == 150)  // newest
    }

    @Test func lastStatReflectsMostRecentRecord() {
        let older = record(tps: 80,  ttft: 200, prompt: 100, completion: 200, secondsAgo: 30)
        let newer = record(tps: 120, ttft: 100, prompt: 300, completion: 400, secondsAgo:  0)
        let rollup = InferenceRollup.compute(from: [older, newer])
        #expect(rollup.lastTokPerSec == 120)
        #expect(rollup.lastTTFTms == 100)
        #expect(rollup.lastPromptTokens == 300)
        #expect(rollup.lastCompletionTokens == 400)
    }
}
