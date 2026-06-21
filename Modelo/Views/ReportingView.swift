import SwiftUI
import SwiftData
import Charts

/// Full-page usage and performance report (handoff §6): stat tiles, per-day
/// charts, and per-model / per-server tables, aggregated over a selectable window.
struct ReportingView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var all: [UsageRecord]
    @State private var timeRange: ReportCalculator.TimeRange = .week

    private var records: [UsageRecord]             { timeRange.filter(all) }
    private var summary: ReportCalculator.Summary  { ReportCalculator.summary(from: records) }
    private var days:    [ReportCalculator.DayBucket]  { ReportCalculator.byDay(from: records) }
    private var models:  [ReportCalculator.ModelStat]  { ReportCalculator.byModel(from: records) }
    private var servers: [ReportCalculator.ServerStat] { ReportCalculator.byServer(from: records) }

    private let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 11), count: 5)

    /// Bridges the `TimeRange` enum to the string-based `SegmentedPills`.
    private var rangeSelection: Binding<String> {
        Binding(
            get: { timeRange.rawValue },
            set: { new in
                if let r = ReportCalculator.TimeRange.allCases.first(where: { $0.rawValue == new }) {
                    timeRange = r
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if all.isEmpty {
                    emptyState
                } else if records.isEmpty {
                    noDataForRange
                } else {
                    LazyVGrid(columns: tileColumns, spacing: 11) {
                        statTile("Requests",   "\(summary.totalRequests)")
                        statTile("Tokens",     tokenString(summary.totalTokens))
                        statTile("Avg tok/s",  summary.avgTokPerSec.map  { String(format: "%.0f", $0) } ?? "—")
                        statTile("Peak tok/s", summary.peakTokPerSec.map { String(format: "%.0f", $0) } ?? "—")
                        statTile("Avg TTFT",   summary.avgTTFTms.map     { String(format: "%.2f s", $0 / 1000) } ?? "—")
                    }
                    if days.count > 1 {
                        chartSection("Requests / day", trailing: "\(summary.totalRequests)") { RequestsChart(buckets: days) }
                        chartSection("Tokens / day", trailing: tokenString(summary.totalTokens)) { TokensChart(buckets: days) }
                        chartSection("Avg tok/s / day", trailing: summary.avgTokPerSec.map { String(format: "%.0f", $0) } ?? "—") { TokPerSecChart(buckets: days) }
                    }
                    if !models.isEmpty  { modelSection }
                    if !servers.isEmpty { serverSection }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Theme.windowBG)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Reports")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textHi)
            Spacer()
            SegmentedPills(options: ReportCalculator.TimeRange.allCases.map(\.rawValue),
                           selection: rangeSelection,
                           boxed: true)
        }
    }

    // MARK: - Stat tiles

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.mono(9.5)).tracking(0.8)
                .foregroundStyle(Theme.textFaint)
            Text(value)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .monospacedDigit()
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
    }

    // MARK: - Chart card

    private func chartSection<C: View>(_ title: String, trailing: String, @ViewBuilder content: () -> C) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                Spacer()
                Text(trailing)
                    .font(.mono(13))
                    .foregroundStyle(Theme.amber)
            }
            .padding(.bottom, 14)
            content().frame(height: 96)
        }
    }

    // MARK: - Tables

    private var modelSection: some View {
        let total = max(1, summary.totalTokens)
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow("By model")
            card {
                tableHeader(["MODEL", "REQUESTS", "TOKENS", "TOK/S", "SHARE"])
                ForEach(models) { stat in
                    HStack(spacing: 12) {
                        cell(stat.shortName, .leading, color: Theme.textHi)
                        cell("\(stat.requests)", .trailing)
                        cell(tokenString(stat.totalTokens), .trailing)
                        cell(stat.avgTokPerSec.map { String(format: "%.0f", $0) } ?? "—", .trailing)
                        shareBar(Double(stat.totalTokens) / Double(total))
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 40)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("By server")
            card {
                tableHeader(["SERVER", "REQUESTS", "TOKENS"])
                ForEach(servers) { stat in
                    HStack(spacing: 12) {
                        cell(stat.serverLabel, .leading, color: Theme.textHi)
                        cell("\(stat.requests)", .trailing)
                        cell(tokenString(stat.totalTokens), .trailing)
                    }
                    .frame(height: 40)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    }
                }
            }
        }
    }

    private func tableHeader(_ cols: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                Text(col)
                    .font(.mono(9.5)).tracking(0.8)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: i == 0 || i == cols.count - 1 ? .leading : .trailing)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func cell(_ text: String, _ align: Alignment, color: Color = Theme.textLo) -> some View {
        Text(text)
            .font(.mono(12))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: align)
    }

    private func shareBar(_ frac: Double) -> some View {
        HStack(spacing: 9) {
            Capsule().fill(Color.white.opacity(0.07)).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Theme.amber).frame(width: g.size.width * min(1, max(0, frac)))
                    }
                }
            Text("\(Int((frac * 100).rounded()))%")
                .font(.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - Card chrome

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("No usage data yet.")
                .font(.mono(12))
                .foregroundStyle(Theme.textFaint)
            Text("Send a message to start generating reports.")
                .font(.mono(11))
                .foregroundStyle(Theme.textFaint.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }

    private var noDataForRange: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("No activity in the selected period.")
                .font(.mono(12))
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }

    // MARK: - Formatting

    private func tokenString(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Chart views

private struct RequestsChart: View {
    let buckets: [ReportCalculator.DayBucket]

    var body: some View {
        Chart(buckets) { b in
            BarMark(x: .value("Day", b.date, unit: .day),
                    y: .value("Requests", b.requests))
                .foregroundStyle(Theme.amber.opacity(0.85))
                .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Int.self) { Text("\(n)").font(.mono(8)) }
                }
            }
        }
    }
}

private struct TokensChart: View {
    let buckets: [ReportCalculator.DayBucket]

    var body: some View {
        Chart(buckets) { b in
            BarMark(x: .value("Day", b.date, unit: .day),
                    y: .value("Prompt", b.promptTokens))
                .foregroundStyle(Theme.textMute.opacity(0.45))
                .cornerRadius(2)
            BarMark(x: .value("Day", b.date, unit: .day),
                    y: .value("Completion", b.completionTokens))
                .foregroundStyle(Theme.amber.opacity(0.8))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            "Prompt":     Theme.textMute.opacity(0.45),
            "Completion": Theme.amber.opacity(0.8),
        ])
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(n >= 1000 ? String(format: "%.0fK", n / 1000) : String(format: "%.0f", n))
                            .font(.mono(8))
                    }
                }
            }
        }
    }
}

private struct TokPerSecChart: View {
    let buckets: [ReportCalculator.DayBucket]

    var body: some View {
        Chart(buckets) { b in
            LineMark(x: .value("Day", b.date, unit: .day),
                     y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(Theme.amber)
                .interpolationMethod(.catmullRom)
            AreaMark(x: .value("Day", b.date, unit: .day),
                     y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.amber.opacity(0.2), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("Day", b.date, unit: .day),
                      y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(Theme.amber)
                .symbolSize(25)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(String(format: "%.0f", n)).font(.mono(8))
                    }
                }
            }
        }
    }
}
