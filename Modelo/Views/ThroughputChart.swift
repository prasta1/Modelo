import SwiftUI
import Charts

/// Compact line chart of recent tok/s values, oldest → newest left to right.
struct ThroughputChart: View {
    let values: [Double]

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Request", i), y: .value("tok/s", v))
                    .foregroundStyle(Theme.Palette.signal)
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Request", i), y: .value("tok/s", v))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Palette.signal.opacity(0.25), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        // No Y axis: the LAST/AVG/PEAK stat block sits directly above each chart
        // and carries the scale. The old `.inset` axis drew its labels inside the
        // plot, overlapping the data — this also frees the full width for the line.
        .chartYAxis(.hidden)
        .frame(height: 80)
    }
}
