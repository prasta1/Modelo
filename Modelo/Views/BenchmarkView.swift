import SwiftUI

/// Load-test sheet (§2.5): fire N requests at a chosen concurrency against the
/// picked model and report TTFT / decode-rate percentiles. Driven by `BenchmarkRunner`.
struct BenchmarkView: View {
    let endpoint: Endpoint
    let modelID: String
    var modelName: String = ""

    @State private var runner = BenchmarkRunner()
    @State private var requests = 16
    @State private var concurrency = 4
    @State private var prompt = "Write a haiku about local inference."
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Eyebrow("Benchmark · \(modelName.isEmpty ? modelID : modelName)")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).font(Theme.metric(11)).foregroundStyle(Theme.textDim)
            }

            stepperRow("Requests", value: $requests, range: 1...256, step: requests < 16 ? 1 : 8)
            stepperRow("Concurrency", value: $concurrency, range: 1...64, step: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(Theme.metric(11)).foregroundStyle(Theme.textLo)
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).fieldChrome(focused: false)
            }

            runControl

            if runner.isRunning {
                Text("\(runner.completed) / \(requests) complete")
                    .font(.mono(11)).monospacedDigit().foregroundStyle(Theme.textDim)
            }
            if let r = runner.report { reportView(r) }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.windowBG)
    }

    private var runControl: some View {
        Button {
            if runner.isRunning { runner.cancel() }
            else { runner.run(endpoint: endpoint, modelID: modelID, prompt: prompt,
                              requests: requests, concurrency: concurrency) }
        } label: {
            Text(runner.isRunning ? "Stop" : "Run benchmark")
                .font(Theme.metric(12).weight(.semibold))
                .foregroundStyle(Theme.windowBG)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(runner.isRunning ? AnyShapeStyle(Theme.Palette.alert) : AnyShapeStyle(Theme.sendGradient),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
    }

    private func reportView(_ r: BenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.line)
            statRow("Succeeded", "\(r.succeeded) / \(r.total)" + (r.failed > 0 ? "  (\(r.failed) failed)" : ""))
            statRow("Wall time", String(format: "%.2f s", r.wallSeconds))
            statRow("Throughput", String(format: "%.1f req/s", r.wallSeconds > 0 ? Double(r.total) / r.wallSeconds : 0))
            statRow("TTFT p50 / p95", String(format: "%.0f / %.0f ms", r.ttftP50 * 1000, r.ttftP95 * 1000))
            statRow("Decode p50 / p95", String(format: "%.0f / %.0f tok/s", r.tpsP50, r.tpsP95))
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.metric(11)).foregroundStyle(Theme.textLo)
            Spacer()
            Text(value).font(.mono(11)).monospacedDigit().foregroundStyle(Theme.textHi)
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(label).font(Theme.metric(12)).foregroundStyle(Theme.textMid)
            Spacer()
            Text("\(value.wrappedValue)").font(.mono(12)).monospacedDigit().foregroundStyle(Theme.textHi)
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }
}
