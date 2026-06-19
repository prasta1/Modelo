import SwiftUI
import Charts

/// A live server card on the Status dashboard (handoff §6).
struct ServerRow: View {
    let server: ServerStat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(Theme.green).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.greenGlow, lineWidth: 3))
                Text(server.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("LIVE").font(.mono(9)).tracking(1).foregroundStyle(Theme.green)
            }

            Text(server.host)
                .font(.mono(10)).foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .padding(.top, 8)

            Divider().overlay(Theme.line).padding(.vertical, 15)

            Grid(horizontalSpacing: 10, verticalSpacing: 13) {
                GridRow {
                    MetricStat(label: "LATENCY", value: server.latency)
                    MetricStat(label: "MODELS",  value: server.models)
                }
                GridRow {
                    MetricStat(label: "REQUESTS",   value: server.requests)
                    MetricStat(label: "THROUGHPUT", value: server.throughput)
                }
            }

            Sparkline(values: server.spark)
                .frame(height: 28)
                .padding(.top, 16)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }
}

/// Tiny amber bar sparkline (handoff §6 — Swift Charts, axes hidden).
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            BarMark(
                x: .value("i", i),
                y: .value("v", v),
                width: .ratio(0.7)
            )
            .foregroundStyle(Theme.amber.opacity(0.42))
            .cornerRadius(1)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
