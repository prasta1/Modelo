import SwiftUI
import Charts

/// Throughput bar chart for Reports (handoff §6). Amber top-weighted bars,
/// axes hidden — real data replaces the seeded samples.
struct ThroughputChart: View {
    let samples: [ChartSample]

    var body: some View {
        Chart(samples) { s in
            BarMark(
                x: .value("t", s.index),
                y: .value("tok/s", s.value),
                width: .ratio(0.66)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [Theme.amber.opacity(0.85), Theme.amber.opacity(0.32)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
