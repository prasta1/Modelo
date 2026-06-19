import SwiftUI

/// Reports screen (handoff §6): stat tiles, throughput + TTFT charts, and a
/// per-model usage table with share bars.
struct ReportingView: View {
    @Environment(AppStore.self) private var store

    private let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 11), count: 5)

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                LazyVGrid(columns: tileColumns, spacing: 11) {
                    ForEach(store.stats) { statTile($0) }
                }

                chartsRow
                usageTable
            }
            .padding(.horizontal, 30).padding(.vertical, 26)
        }
        .background(Theme.windowBG)
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return HStack {
            Text("Reports").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textHi)
            Spacer()
            SegmentedPills(options: ["Today", "7 days", "30 days"],
                           selection: $store.reportRange, boxed: true)
            Label("Export", systemImage: "square.and.arrow.down")
                .font(.system(size: 12)).foregroundStyle(Theme.textLo)
                .padding(.horizontal, 13).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(Color.white.opacity(0.08)))
        }
    }

    // MARK: Stat tiles

    private func statTile(_ s: StatTile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.label).font(.mono(9.5)).tracking(0.8).foregroundStyle(Theme.textFaint)
            Text(s.value)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .padding(.top, 9)
            Text(s.sub).font(.mono(10)).foregroundStyle(Theme.textDim).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
    }

    // MARK: Charts

    private var chartsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            card {
                chartHeader(title: "Throughput",
                            subtitle: "tokens / second · last 24h",
                            trailing: "44 avg")
                ThroughputChart(samples: store.throughput).frame(height: 118)
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1.5)

            card {
                chartHeader(title: "Time to first token", subtitle: nil, trailing: "280ms")
                TTFTChart(samples: store.ttft).frame(height: 118)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func chartHeader(title: String, subtitle: String?, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textHi)
            if let subtitle { Text(subtitle).font(.mono(11)).foregroundStyle(Theme.textDim) }
            Spacer()
            Text(trailing).font(.mono(13)).foregroundStyle(Theme.amber)
        }
        .padding(.bottom, 16)
    }

    // MARK: Usage table

    private var usageTable: some View {
        let weights: [CGFloat] = [2, 1, 1, 1, 1.4]
        return VStack(spacing: 0) {
            GeometryReader { geo in
                let widths = columnWidths(total: geo.size.width, weights: weights)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        usageCell("MODEL", widths[0], .leading)
                        usageCell("REQUESTS", widths[1], .trailing)
                        usageCell("TOKENS", widths[2], .trailing)
                        usageCell("TOK/S", widths[3], .trailing)
                        usageCell("SHARE", widths[4], .leading)
                    }
                    .font(.mono(9.5)).tracking(0.8).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

                    ForEach(store.usage) { row in
                        usageRow(row, widths: widths)
                    }
                }
            }
            .frame(height: CGFloat(store.usage.count) * 45 + 41)
        }
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }

    private func usageRow(_ row: UsageRow, widths: [CGFloat]) -> some View {
        HStack(spacing: 12) {
            Text(row.model).font(.mono(12.5)).foregroundStyle(Theme.textHi)
                .lineLimit(1).frame(width: widths[0], alignment: .leading)
            Text(row.requests).font(.mono(12)).foregroundStyle(Theme.textLo)
                .frame(width: widths[1], alignment: .trailing)
            Text(row.tokens).font(.mono(12)).foregroundStyle(Theme.textLo)
                .frame(width: widths[2], alignment: .trailing)
            Text(row.rate).font(.mono(12)).foregroundStyle(Theme.textLo)
                .frame(width: widths[3], alignment: .trailing)
            HStack(spacing: 9) {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Theme.amber).frame(width: g.size.width * row.share)
                        }
                    }
                Text(row.sharePercent).font(.mono(10.5)).foregroundStyle(Theme.textDim)
                    .frame(width: 30, alignment: .trailing)
            }
            .frame(width: widths[4])
        }
        .padding(.horizontal, 18).frame(height: 45)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.04)) }
    }

    private func usageCell(_ text: String, _ width: CGFloat, _ align: Alignment) -> some View {
        Text(text).frame(width: width, alignment: align)
    }

    private func columnWidths(total: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        let gaps = CGFloat(weights.count - 1) * 12
        let available = max(0, total - 36 - gaps)
        let sum = weights.reduce(0, +)
        return weights.map { available * $0 / sum }
    }

    // MARK: Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }
}
