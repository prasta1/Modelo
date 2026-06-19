import SwiftUI

/// Context-window telemetry: a monospaced readout over a hand-built gauge whose
/// fill shifts green → amber → red as the window fills.
struct ContextBar: View {
    let used: Int
    let window: Int

    private var fraction: Double {
        guard window > 0 else { return 0 }
        return min(1, Double(used) / Double(window))
    }

    private var barColor: Color {
        switch fraction {
        case ..<0.6:  Theme.Palette.live
        case ..<0.85: Theme.Palette.idle
        default:      Theme.Palette.alert
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Eyebrow("context", color: Theme.Palette.inkDim)
                Spacer()
                Text("\(used.formatted()) / \(window.formatted())")
                    .font(Theme.metric(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.inkDim)
                Text("\(Int(fraction * 100))%")
                    .font(Theme.metric(11))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }

            // A track + animated fill, so the gauge feels like a live instrument
            // rather than a stock progress bar we can't fully theme.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.panelHigh)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * fraction))
                        .shadow(color: barColor.opacity(0.6), radius: 4)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 5)
        }
    }
}
