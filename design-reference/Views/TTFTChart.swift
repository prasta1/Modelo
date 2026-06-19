import SwiftUI
import Charts

/// Time-to-first-token line + area chart for Reports (handoff §6). Amber line
/// over a 0.10-opacity amber area; axes hidden.
struct TTFTChart: View {
    let samples: [ChartSample]

    var body: some View {
        Chart(samples) { s in
            AreaMark(
                x: .value("t", s.index),
                y: .value("ms", s.value)
            )
            .foregroundStyle(Theme.amber.opacity(0.10))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("t", s.index),
                y: .value("ms", s.value)
            )
            .foregroundStyle(Theme.amber)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 210...340)     // matches the mock's vmin/vmax framing
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
