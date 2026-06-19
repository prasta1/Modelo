import Foundation

/// Pure aggregation functions for the reporting view. No I/O, fully testable.
enum ReportCalculator {

    // MARK: - Time range

    enum TimeRange: String, CaseIterable, Identifiable {
        case week    = "7 Days"
        case month   = "30 Days"
        case allTime = "All Time"
        var id: String { rawValue }

        /// Returns only the records within this range relative to `referenceDate`.
        func filter(_ records: [UsageRecord], referenceDate: Date = Date()) -> [UsageRecord] {
            switch self {
            case .allTime: return records
            case .week:
                let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: referenceDate)!
                return records.filter { $0.timestamp >= cutoff }
            case .month:
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: referenceDate)!
                return records.filter { $0.timestamp >= cutoff }
            }
        }
    }

    // MARK: - Output types

    struct Summary {
        let totalRequests: Int
        let totalPromptTokens: Int
        let totalCompletionTokens: Int
        let avgTokPerSec: Double?
        let peakTokPerSec: Double?
        let avgTTFTms: Double?

        var totalTokens: Int { totalPromptTokens + totalCompletionTokens }

        static let empty = Summary(
            totalRequests: 0, totalPromptTokens: 0, totalCompletionTokens: 0,
            avgTokPerSec: nil, peakTokPerSec: nil, avgTTFTms: nil
        )
    }

    /// Aggregated stats for one calendar day.
    struct DayBucket: Identifiable {
        let date: Date      // start of the calendar day
        let requests: Int
        let promptTokens: Int
        let completionTokens: Int
        let avgTokPerSec: Double
        var id: Date { date }
        var totalTokens: Int { promptTokens + completionTokens }
    }

    struct ModelStat: Identifiable {
        let modelID: String
        let requests: Int
        let totalTokens: Int
        let avgTokPerSec: Double?
        var id: String { modelID }
        /// Publisher-stripped short name for display.
        var shortName: String {
            modelID.split(separator: "/").last.map(String.init) ?? modelID
        }
    }

    struct ServerStat: Identifiable {
        let serverLabel: String
        let requests: Int
        let totalTokens: Int
        var id: String { serverLabel }
    }

    // MARK: - Aggregations

    static func summary(from records: [UsageRecord]) -> Summary {
        guard !records.isEmpty else { return .empty }
        let tps  = records.map { $0.tokensPerSecond }
        let ttft = records.map { $0.ttftMillis }
        return Summary(
            totalRequests: records.count,
            totalPromptTokens: records.reduce(0) { $0 + $1.promptTokens },
            totalCompletionTokens: records.reduce(0) { $0 + $1.completionTokens },
            avgTokPerSec: tps.reduce(0, +) / Double(records.count),
            peakTokPerSec: tps.max(),
            avgTTFTms: Double(ttft.reduce(0, +)) / Double(records.count)
        )
    }

    /// Groups records by calendar day, sorted oldest → newest.
    static func byDay(from records: [UsageRecord]) -> [DayBucket] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return grouped.map { day, recs in
            let tps = recs.map { $0.tokensPerSecond }
            return DayBucket(
                date: day,
                requests: recs.count,
                promptTokens: recs.reduce(0) { $0 + $1.promptTokens },
                completionTokens: recs.reduce(0) { $0 + $1.completionTokens },
                avgTokPerSec: tps.reduce(0, +) / Double(recs.count)
            )
        }.sorted { $0.date < $1.date }
    }

    /// Groups records by model ID, sorted by request count descending.
    static func byModel(from records: [UsageRecord]) -> [ModelStat] {
        Dictionary(grouping: records) { $0.modelID }.map { model, recs in
            let tps = recs.map { $0.tokensPerSecond }
            return ModelStat(
                modelID: model,
                requests: recs.count,
                totalTokens: recs.reduce(0) { $0 + $1.promptTokens + $1.completionTokens },
                avgTokPerSec: recs.isEmpty ? nil : tps.reduce(0, +) / Double(recs.count)
            )
        }.sorted { $0.requests > $1.requests }
    }

    /// Groups records by server label, sorted by request count descending.
    static func byServer(from records: [UsageRecord]) -> [ServerStat] {
        Dictionary(grouping: records) { $0.serverLabel }.map { server, recs in
            ServerStat(
                serverLabel: server,
                requests: recs.count,
                totalTokens: recs.reduce(0) { $0 + $1.promptTokens + $1.completionTokens }
            )
        }.sorted { $0.requests > $1.requests }
    }
}
