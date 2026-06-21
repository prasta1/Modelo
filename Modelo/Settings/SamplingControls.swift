import SwiftUI

/// The shared sampling-parameter editor (§1.4): one labelled on/off pill + slider per
/// numeric control, plus a max-tokens field. "Off" sets the field to `nil` — meaning
/// it isn't sent (global tab) or inherits the default (per-conversation / preset).
///
/// Reused by Settings ▸ Sampling (global defaults), the per-conversation popover, and
/// the preset editor, so all three stay visually and behaviourally identical.
struct SamplingControls: View {
    @Binding var params: SamplingParams

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            doubleRow("Temperature", $params.temperature, range: 0...2, step: 0.05, fallback: 0.7)
            doubleRow("Top P", $params.topP, range: 0...1, step: 0.05, fallback: 0.9)
            doubleRow("Frequency penalty", $params.frequencyPenalty, range: -2...2, step: 0.1, fallback: 0)
            doubleRow("Presence penalty", $params.presencePenalty, range: -2...2, step: 0.1, fallback: 0)
            intRow("Max tokens", $params.maxTokens, fallback: 2048)
        }
    }

    /// Label + value readout + on/off pill, with a slider shown when enabled.
    private func doubleRow(_ label: String, _ value: Binding<Double?>,
                           range: ClosedRange<Double>, step: Double, fallback: Double) -> some View {
        let on = Binding(get: { value.wrappedValue != nil },
                         set: { value.wrappedValue = $0 ? (value.wrappedValue ?? fallback) : nil })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Theme.metric(12)).foregroundStyle(Theme.textMid)
                Spacer()
                Text(value.wrappedValue.map { String(format: "%.2f", $0) } ?? "default")
                    .font(.mono(11)).monospacedDigit()
                    .foregroundStyle(value.wrappedValue == nil ? Theme.textFaint : Theme.textLo)
                PillToggle(isOn: on)
            }
            if value.wrappedValue != nil {
                Slider(value: Binding(get: { value.wrappedValue ?? fallback },
                                      set: { value.wrappedValue = $0 }),
                       in: range, step: step)
                    .tint(Theme.amber)
            }
        }
    }

    private func intRow(_ label: String, _ value: Binding<Int?>, fallback: Int) -> some View {
        let on = Binding(get: { value.wrappedValue != nil },
                         set: { value.wrappedValue = $0 ? (value.wrappedValue ?? fallback) : nil })
        return HStack {
            Text(label).font(Theme.metric(12)).foregroundStyle(Theme.textMid)
            Spacer()
            if value.wrappedValue != nil {
                TextField("tokens", value: Binding(get: { value.wrappedValue ?? fallback },
                                                   set: { value.wrappedValue = max(1, $0) }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .fieldChrome(focused: false)
                    .frame(width: 90)
            } else {
                Text("default").font(.mono(11)).foregroundStyle(Theme.textFaint)
            }
            PillToggle(isOn: on)
        }
    }
}
