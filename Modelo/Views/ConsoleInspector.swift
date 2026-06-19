import SwiftUI
import SwiftData

/// The Inspector panel — inference console for the active server.
/// Toggled with ⌘I or the toolbar button. Shown only when a model is picked.
/// `activeModel` is the model the user picked in the chat picker — shown in
/// preference to the server's polled snapshot, which may reflect a different
/// model that LM Studio happened to have loaded at poll time.
struct ConsoleInspector: View {
    let server: Server
    let activeModel: LMStudioModel?
    let snapshot: ModelSnapshot?

    var body: some View {
        ServerRecordsConsole(server: server, activeModel: activeModel, snapshot: snapshot)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }
}

// MARK: - Data container

private struct ServerRecordsConsole: View {
    let server: Server
    let activeModel: LMStudioModel?
    let snapshot: ModelSnapshot?
    @Query private var records: [UsageRecord]

    init(server: Server, activeModel: LMStudioModel?, snapshot: ModelSnapshot?) {
        self.server = server
        self.activeModel = activeModel
        self.snapshot = snapshot
        let label = server.label
        _records = Query(
            filter: #Predicate<UsageRecord> { $0.serverLabel == label },
            sort: \UsageRecord.timestamp, order: .reverse
        )
    }

    var body: some View {
        let rollup = InferenceRollup.compute(from: Array(records.prefix(20)).reversed())
        ConsolePanel(server: server, activeModel: activeModel, snapshot: snapshot, rollup: rollup)
    }
}

// MARK: - Panel

struct ConsolePanel: View {
    let server: Server
    let activeModel: LMStudioModel?
    let snapshot: ModelSnapshot?
    let rollup: InferenceRollup

    /// The model to display — prefer the one the user actually picked in the
    /// chat header over whatever LM Studio happened to report as loaded.
    private var displayModel: LMStudioModel? { activeModel ?? snapshot?.models.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(server.label, color: Theme.Palette.inkDim, size: 11)

            // Active model
            Group {
                Eyebrow("Active Model")
                if let model = displayModel {
                    LoadedModelRow(model: model)
                } else {
                    NoModelRow()
                }
            }

            Divider().overlay(Theme.Palette.strokeStrong)

            // Inference stats
            if rollup.requestCount == 0 {
                Text("No requests this session")
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .padding(.vertical, 4)
                Spacer()
            } else {
                // Tok/s
                MetricStat(
                    label: "Decode Speed · tok/s",
                    last: rollup.lastTokPerSec.map { String(format: "%.0f", $0) },
                    avg:  rollup.avgTokPerSec.map  { String(format: "%.0f", $0) },
                    peak: rollup.peakTokPerSec.map { String(format: "%.0f", $0) }
                )
                if !rollup.tokPerSecHistory.isEmpty {
                    ThroughputChart(values: rollup.tokPerSecHistory)
                        .frame(minHeight: 50, maxHeight: .infinity)
                }

                Divider().overlay(Theme.Palette.stroke)

                // TTFT
                MetricStat(
                    label: "Time to First Token · ms",
                    last: rollup.lastTTFTms.map { "\($0)" },
                    avg:  rollup.avgTTFTms.map  { String(format: "%.0f", $0) },
                    peak: rollup.peakTTFTms.map { "\($0)" }
                )
                if !rollup.ttftHistory.isEmpty {
                    TTFTChart(values: rollup.ttftHistory)
                        .frame(minHeight: 50, maxHeight: .infinity)
                }

                Divider().overlay(Theme.Palette.stroke)

                // Per-turn token counts + request count
                HStack(spacing: 20) {
                    miniStat("Requests",   value: "\(rollup.requestCount)")
                    if let p = rollup.lastPromptTokens   { miniStat("Prefill",    value: "\(p)") }
                    if let c = rollup.lastCompletionTokens { miniStat("Completion", value: "\(c)") }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.panel)
    }

    private func miniStat(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading.uppercased())
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.inkFaint)
            Text(value)
                .font(Theme.metric(15))
                .foregroundStyle(Theme.Palette.ink)
                .monospacedDigit()
        }
    }
}
