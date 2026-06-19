import SwiftUI
import SwiftData
import Charts

/// Full-page usage and performance report — requests, tokens, speed, and TTFT
/// aggregated over a selectable time window and broken down by model and server.
struct ReportingView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var all: [UsageRecord]
    @State private var timeRange: ReportCalculator.TimeRange = .week

    private var records: [UsageRecord]             { timeRange.filter(all) }
    private var summary: ReportCalculator.Summary  { ReportCalculator.summary(from: records) }
    private var days:    [ReportCalculator.DayBucket]  { ReportCalculator.byDay(from: records) }
    private var models:  [ReportCalculator.ModelStat]  { ReportCalculator.byModel(from: records) }
    private var servers: [ReportCalculator.ServerStat] { ReportCalculator.byServer(from: records) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if all.isEmpty {
                    emptyState
                } else if records.isEmpty {
                    noDataForRange
                } else {
                    summaryRow
                    if days.count > 1 {
                        chartSection("Requests / Day")  { RequestsChart(buckets: days) }
                        chartSection("Tokens / Day")    { TokensChart(buckets: days) }
                        chartSection("Avg tok/s / Day") { TokPerSecChart(buckets: days) }
                    }
                    if !models.isEmpty  { modelSection }
                    if !servers.isEmpty { serverSection }
                }
            }
            .padding(24)
        }
        .background(InstrumentBackground())
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Eyebrow("Reports", color: Theme.Palette.inkDim, size: 12)
            Spacer()
            Picker("", selection: $timeRange) {
                ForEach(ReportCalculator.TimeRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .colorScheme(.dark)
        }
    }

    // MARK: - Summary cards

    private var summaryRow: some View {
        HStack(spacing: 12) {
            summaryCard("Requests",   value: "\(summary.totalRequests)")
            summaryCard("Tokens",     value: tokenString(summary.totalTokens))
            summaryCard("Avg tok/s",  value: summary.avgTokPerSec.map  { String(format: "%.0f", $0) } ?? "—")
            summaryCard("Peak tok/s", value: summary.peakTokPerSec.map { String(format: "%.0f", $0) } ?? "—")
            summaryCard("Avg TTFT",   value: summary.avgTTFTms.map     { String(format: "%.0f ms", $0) } ?? "—")
        }
    }

    private func summaryCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            Text(value)
                .font(Theme.metric(20))
                .foregroundStyle(Theme.Palette.ink)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.Palette.panel, radius: 10)
    }

    // MARK: - Chart wrapper

    private func chartSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            content()
                .padding(12)
                .panel(Theme.Palette.panel, radius: 10)
        }
    }

    // MARK: - Model table

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("By Model")
            VStack(spacing: 0) {
                tableHeader(["Model", "Requests", "Tokens", "Avg tok/s"])
                ForEach(models) { stat in
                    tableRow([
                        stat.shortName,
                        "\(stat.requests)",
                        tokenString(stat.totalTokens),
                        stat.avgTokPerSec.map { String(format: "%.0f", $0) } ?? "—",
                    ], first: models.first?.id == stat.id)
                }
            }
            .panel(Theme.Palette.panel, radius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Server table

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("By Server")
            VStack(spacing: 0) {
                tableHeader(["Server", "Requests", "Tokens"])
                ForEach(servers) { stat in
                    tableRow([
                        stat.serverLabel,
                        "\(stat.requests)",
                        tokenString(stat.totalTokens),
                    ], first: servers.first?.id == stat.id)
                }
            }
            .panel(Theme.Palette.panel, radius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Table helpers

    private func tableHeader(_ cols: [String]) -> some View {
        HStack {
            ForEach(cols, id: \.self) { col in
                Text(col.uppercased())
                    .font(Theme.label(9))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: col == cols.first ? .leading : .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Palette.panelHigh)
    }

    private func tableRow(_ cols: [String], first: Bool) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                Text(col)
                    .font(i == 0 ? Theme.mono(12) : Theme.metric(12))
                    .foregroundStyle(i == 0 ? Theme.Palette.ink : Theme.Palette.inkDim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Theme.Palette.stroke).frame(height: 1)
            }
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text("No usage data yet.")
                .font(Theme.metric(12))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text("Send a message to start generating reports.")
                .font(Theme.metric(11))
                .foregroundStyle(Theme.Palette.inkFaint.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }

    private var noDataForRange: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text("No activity in the selected period.")
                .font(Theme.metric(12))
                .foregroundStyle(Theme.Palette.inkFaint)
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
                .foregroundStyle(Theme.Palette.signal.opacity(0.85))
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
                    if let n = v.as(Int.self) { Text("\(n)").font(Theme.metric(8)) }
                }
            }
        }
        .frame(height: 80)
    }
}

private struct TokensChart: View {
    let buckets: [ReportCalculator.DayBucket]

    var body: some View {
        Chart(buckets) { b in
            BarMark(x: .value("Day", b.date, unit: .day),
                    y: .value("Prompt", b.promptTokens))
                .foregroundStyle(Theme.Palette.inkDim.opacity(0.55))
                .cornerRadius(2)
            BarMark(x: .value("Day", b.date, unit: .day),
                    y: .value("Completion", b.completionTokens))
                .foregroundStyle(Theme.Palette.signal.opacity(0.75))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            "Prompt":     Theme.Palette.inkDim.opacity(0.55),
            "Completion": Theme.Palette.signal.opacity(0.75),
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
                            .font(Theme.metric(8))
                    }
                }
            }
        }
        .frame(height: 80)
    }
}

private struct TokPerSecChart: View {
    let buckets: [ReportCalculator.DayBucket]

    var body: some View {
        Chart(buckets) { b in
            LineMark(x: .value("Day", b.date, unit: .day),
                     y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(Theme.Palette.signal)
                .interpolationMethod(.catmullRom)
            AreaMark(x: .value("Day", b.date, unit: .day),
                     y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.Palette.signal.opacity(0.2), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("Day", b.date, unit: .day),
                      y: .value("tok/s", b.avgTokPerSec))
                .foregroundStyle(Theme.Palette.signal)
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
                        Text(String(format: "%.0f", n)).font(Theme.metric(8))
                    }
                }
            }
        }
        .frame(height: 80)
    }
}
