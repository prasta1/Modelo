import SwiftUI
import Charts

/// Compact bar chart of recent TTFT (ms) values, oldest → newest left to right.
struct TTFTChart: View {
    let values: [Double]

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("Request", i), y: .value("ms", v))
                    .foregroundStyle(Theme.purple.opacity(0.75))
                    .cornerRadius(2)
            }
        }
        // Pad domain by ±0.5 so the first and last bars aren't half-clipped
        // (Charts centers each BarMark on its x-value, so x=0 sits on the edge).
        .chartXScale(domain: -0.5...Double(max(values.count - 1, 0)) + 0.5)
        .chartXAxis(.hidden)
        // No Y axis: the LAST/AVG/PEAK stat block above carries the scale, and the
        // old `.inset` axis drew its labels inside the plot, overlapping the bars.
        .chartYAxis(.hidden)
        .frame(height: 80)
    }
}
