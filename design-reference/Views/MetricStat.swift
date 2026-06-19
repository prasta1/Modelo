import SwiftUI

/// Small labelled metric used in the 2×2 grid on Status server cards
/// (LATENCY / MODELS / REQUESTS / THROUGHPUT).
struct MetricStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.mono(9)).tracking(0.8).foregroundStyle(Theme.textFaint)
            Text(value)
                .font(.mono(13.5)).foregroundStyle(Theme.textHi)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
