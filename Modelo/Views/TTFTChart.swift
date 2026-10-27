import SwiftUI
import Charts

/// Compact bar chart of recent TTFT (ms) values, oldest → newest left to right.
struct TTFTChart: View {
    let values: [Double]

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                // Categorical (not continuous) x so Charts has a real step size
                // to size bars from, instead of falling back to a fixed width.
                BarMark(x: .value("Request", String(i)), y: .value("ms", v))
                    .foregroundStyle(Theme.purple.opacity(0.75))
                    .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        // No Y axis: the LAST/AVG/PEAK stat block above carries the scale, and the
        // old `.inset` axis drew its labels inside the plot, overlapping the bars.
        .chartYAxis(.hidden)
        .frame(height: 80)
    }
}
