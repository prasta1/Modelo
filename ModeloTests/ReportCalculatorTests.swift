import Testing
import Foundation
@testable import Modelo

@Suite("ReportCalculator")
struct ReportCalculatorTests {

    // MARK: - Helpers

    private func record(tps: Double = 80, ttft: Int = 200,
                        prompt: Int = 100, completion: Int = 200,
                        model: String = "qwen3", server: String = "Studio",
                        daysAgo: Double = 0) -> UsageRecord {
        let r = UsageRecord(modelID: model, serverLabel: server,
                            promptTokens: prompt, completionTokens: completion,
                            tokensPerSecond: tps, ttftMillis: ttft)
        r.timestamp = Date(timeIntervalSinceNow: -daysAgo * 86400)
        return r
    }

    // MARK: - Summary

    @Test func summaryEmpty() {
        let s = ReportCalculator.summary(from: [])
        #expect(s.totalRequests == 0)
        #expect(s.avgTokPerSec == nil)
    }

    @Test func summaryTotalsAndAverages() {
        let records = [
            record(tps: 60, ttft: 300, prompt: 100, completion: 200),
            record(tps: 100, ttft: 100, prompt: 200, completion: 300),
        ]
        let s = ReportCalculator.summary(from: records)
        #expect(s.totalRequests == 2)
        #expect(s.totalPromptTokens == 300)
        #expect(s.totalCompletionTokens == 500)
        #expect(s.totalTokens == 800)
        #expect(s.avgTokPerSec == 80)
        #expect(s.peakTokPerSec == 100)
        #expect(s.avgTTFTms == 200)
    }

    // MARK: - Time range filter

    @Test func timeRangeWeekKeepsRecent() {
        let ref = Date()
        let recent  = record(daysAgo: 3)
        let old     = record(daysAgo: 10)
        let result = ReportCalculator.TimeRange.week.filter([recent, old], referenceDate: ref)
        #expect(result.count == 1)
        #expect(result.first?.timestamp == recent.timestamp)
    }

    @Test func timeRangeAllTimeKeepsEverything() {
        let records = [record(daysAgo: 100), record(daysAgo: 200)]
        let result = ReportCalculator.TimeRange.allTime.filter(records)
        #expect(result.count == 2)
    }

    // MARK: - byDay

    @Test func byDayGroupsAndSorts() {
        let r1 = record(tps: 80, prompt: 100, completion: 50, daysAgo: 2)
        let r2 = record(tps: 120, prompt: 200, completion: 100, daysAgo: 0)
        let buckets = ReportCalculator.byDay(from: [r1, r2])
        #expect(buckets.count == 2)
        #expect(buckets[0].date < buckets[1].date)   // sorted oldest first
        #expect(buckets[0].requests == 1)
        #expect(buckets[0].promptTokens == 100)
    }

    @Test func byDaySameDayMerges() {
        // Two records on the same day
        let r1 = record(tps: 60, prompt: 100, completion: 50)
        let r2 = record(tps: 100, prompt: 200, completion: 100)
        let buckets = ReportCalculator.byDay(from: [r1, r2])
        #expect(buckets.count == 1)
        #expect(buckets[0].requests == 2)
        #expect(buckets[0].promptTokens == 300)
        #expect(buckets[0].avgTokPerSec == 80)
    }

    // MARK: - byModel

    @Test func byModelSortsByRequestCountDesc() {
        let records = [
            record(model: "qwen3"),
            record(model: "qwen3"),
            record(model: "gemma"),
        ]
        let stats = ReportCalculator.byModel(from: records)
        #expect(stats[0].modelID == "qwen3")
        #expect(stats[0].requests == 2)
        #expect(stats[1].modelID == "gemma")
    }

    @Test func byModelShortNameStripsPublisher() {
        let r = record(model: "bartowski/gemma-3-27b-GGUF")
        let stats = ReportCalculator.byModel(from: [r])
        #expect(stats[0].shortName == "gemma-3-27b-GGUF")
    }

    @Test func byModelTotalsTokens() {
        let records = [
            record(prompt: 100, completion: 200, model: "m"),
            record(prompt: 300, completion: 400, model: "m"),
        ]
        let stats = ReportCalculator.byModel(from: records)
        #expect(stats[0].totalTokens == 1000)
    }

    // MARK: - byServer

    @Test func byServerSortsByRequestCountDesc() {
        let records = [
            record(server: "Studio"),
            record(server: "Studio"),
            record(server: "MacBook"),
        ]
        let stats = ReportCalculator.byServer(from: records)
        #expect(stats[0].serverLabel == "Studio")
        #expect(stats[0].requests == 2)
    }
}
