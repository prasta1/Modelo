import SwiftUI

/// A labelled three-column stat block: LAST · AVG · PEAK.
/// Used throughout the inference console for tok/s, TTFT, etc.
struct MetricStat: View {
    let label: String
    let last: String?
    let avg: String?
    let peak: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !label.isEmpty {
                Eyebrow(label)
            }
            HStack(spacing: 20) {
                column("LAST", value: last)
                column("AVG",  value: avg)
                column("PEAK", value: peak)
            }
        }
    }

    private func column(_ heading: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.mono(9))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
            Text(value ?? "—")
                .font(.mono(15))
                .foregroundStyle(value != nil ? Theme.textHi : Theme.textFaint)
                .monospacedDigit()
        }
    }
}
