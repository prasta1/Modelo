import SwiftUI
import SwiftData
import Charts

/// Full-page usage and performance report (handoff §6): stat tiles, per-day
/// charts, and per-model / per-server tables, aggregated over a selectable window.
struct ReportingView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var all: [UsageRecord]
    @Environment(\.modelContext) private var context
    @AppStorage(UsageRetention.key) private var retentionDays = 0
    @State private var timeRange: ReportCalculator.TimeRange = .week
    @State private var modelSortKey: ModelSortKey = .requests
    @State private var modelSortAscending: Bool = false
    @State private var serverSortKey: ServerSortKey = .requests
    @State private var serverSortAscending: Bool = false

    private var records: [UsageRecord]             { timeRange.filter(all) }
    private var sortedModels: [ReportCalculator.ModelStat] {
        models.sorted { a, b in
            let ascending = modelSortAscending
            let result: Bool = switch modelSortKey {
            case .model:       a.shortName < b.shortName
            case .requests:    a.requests < b.requests
            case .tokens:      a.totalTokens < b.totalTokens
            case .tokPerSec:   (a.avgTokPerSec ?? 0) < (b.avgTokPerSec ?? 0)
            }
            return ascending ? result : !result
        }
    }

    private enum ModelSortKey: String, CaseIterable {
        case model = "MODEL"
        case requests = "REQUESTS"
        case tokens = "TOKENS"
        case tokPerSec = "TOK/S"
    }

    private var sortedServers: [ReportCalculator.ServerStat] {
        servers.sorted { a, b in
            let ascending = serverSortAscending
            let result: Bool = switch serverSortKey {
            case .server: a.serverLabel < b.serverLabel
            case .requests: a.requests < b.requests
            case .tokens: a.totalTokens < b.totalTokens
            }
            return ascending ? result : !result
        }
    }

    private enum ServerSortKey: String, CaseIterable {
        case server = "SERVER"
        case requests = "REQUESTS"
        case tokens = "TOKENS"
    }

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

    /// Prunes on the next runloop tick so the delete+save never mutates the backing
    /// `@Query` synchronously inside a tap/onChange, which would flash the UI.
    private func prune() {
        let days = retentionDays
        Task { @MainActor in
            UsageRetention.prune(in: context, retentionDays: days)
        }
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
        .onAppear(perform: prune)
        .onChange(of: retentionDays) { prune() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Reports")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textHi)
            Spacer()
            retentionControl
            SegmentedPills(options: ReportCalculator.TimeRange.allCases.map(\.rawValue),
                           selection: rangeSelection,
                           boxed: true)
        }
    }

    /// Usage-retention options (§3.4); `days == 0` keeps everything forever.
    private static let retentionOptions: [(label: String, days: Int)] =
        [("∞", 0), ("7d", 7), ("14d", 14), ("30d", 30), ("60d", 60), ("90d", 90)]

    /// Always-visible retention selector. Uses `SegmentedPills` (not a `Menu`) so a
    /// re-render — e.g. the prune mutating the `@Query` that backs this page — can't
    /// dismiss an open popover mid-selection.
    private var retentionControl: some View {
        HStack(spacing: 7) {
            Text("KEEP")
                .font(.mono(9.5)).tracking(1.2)
                .foregroundStyle(Theme.textDim)
            SegmentedPills(options: Self.retentionOptions.map(\.label),
                           selection: retentionSelection,
                           boxed: true)
        }
        .help("How long to keep usage records before pruning them. ∞ = keep forever.")
    }

    /// Bridges the `Int` retention days to the string-based `SegmentedPills`.
    private var retentionSelection: Binding<String> {
        Binding(
            get: { Self.retentionOptions.first { $0.days == retentionDays }?.label ?? "∞" },
            set: { new in
                if let match = Self.retentionOptions.first(where: { $0.label == new }) {
                    retentionDays = match.days
                }
            }
        )
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
                modelTableHeader
                ForEach(sortedModels) { stat in
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

    private var modelTableHeader: some View {
        HStack(spacing: 12) {
            sortHeader("MODEL", key: ModelSortKey.model, alignment: .leading)
            sortHeader("REQUESTS", key: ModelSortKey.requests, alignment: .trailing)
            sortHeader("TOKENS", key: ModelSortKey.tokens, alignment: .trailing)
            sortHeader("TOK/S", key: ModelSortKey.tokPerSec, alignment: .trailing)
            Text("SHARE")
                .font(.mono(9.5)).tracking(0.8)
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func sortHeader(_ title: String, key: ModelSortKey, alignment: Alignment) -> some View {
        let isActive = modelSortKey == key
        return Button {
            if modelSortKey == key {
                modelSortAscending.toggle()
            } else {
                modelSortKey = key
                modelSortAscending = (key == .model)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.mono(9.5)).tracking(0.8)
                    .foregroundStyle(isActive ? Theme.amber : Theme.textFaint)
                Text(modelSortKey == key ? (modelSortAscending ? "▲" : "▼") : "")
                    .font(.mono(8))
                    .foregroundStyle(isActive ? Theme.amber : .clear)
                    .frame(width: 8)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private func sortHeader(_ title: String, key: ServerSortKey, alignment: Alignment) -> some View {
        let isActive = serverSortKey == key
        return Button {
            if serverSortKey == key {
                serverSortAscending.toggle()
            } else {
                serverSortKey = key
                serverSortAscending = (key == .server)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.mono(9.5)).tracking(0.8)
                    .foregroundStyle(isActive ? Theme.amber : Theme.textFaint)
                Text(serverSortKey == key ? (serverSortAscending ? "▲" : "▼") : "")
                    .font(.mono(8))
                    .foregroundStyle(isActive ? Theme.amber : .clear)
                    .frame(width: 8)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("By server")
            card {
                serverTableHeader
                ForEach(sortedServers) { stat in
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

    private var serverTableHeader: some View {
        HStack(spacing: 12) {
            sortHeader("SERVER", key: ServerSortKey.server, alignment: .leading)
            sortHeader("REQUESTS", key: ServerSortKey.requests, alignment: .trailing)
            sortHeader("TOKENS", key: ServerSortKey.tokens, alignment: .trailing)
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
