import SwiftUI
import SwiftData

/// Full-page monitoring console — one card per LM Studio server.
/// All servers appear: offline cards are dimmed but present.
struct StatusView: View {
    /// Called with (server, modelID) when the user pins a loaded model. nil hides the pin action.
    var onPin: ((Server, String) -> Void)? = nil
    /// Called with (server, modelID) when the user unpins a loaded model. nil hides the unpin action.
    var onUnpin: ((Server, String) -> Void)? = nil

    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(servers.filter { $0.kind == .lmStudio }) { server in
                    ServerConsoleCard(
                        server: server,
                        status: registry.status(for: server),
                        snapshot: monitor.snapshot(for: server),
                        onPin: onPin.map { cb in { modelID in cb(server, modelID) } },
                        onUnpin: onUnpin.map { cb in { modelID in cb(server, modelID) } }
                    )
                }
            }
            .padding(20)
        }
        .background(InstrumentBackground())
    }
}

// MARK: - Server card

private struct ServerConsoleCard: View {
    let server: Server
    let status: ServerStatus
    let snapshot: ModelSnapshot?
    var onPin: ((String) -> Void)? = nil
    var onUnpin: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.Palette.strokeStrong).frame(height: 1)
                }
            ServerCardBody(server: server, snapshot: snapshot, onPin: onPin, onUnpin: onUnpin)
                .padding(12)
        }
        .panel(Theme.Palette.panel, radius: 10)
        .opacity(status == .offline ? 0.6 : 1)
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            StatusLED(status: status, size: 6)
            Text(server.label)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
            statusLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Palette.panelHigh)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .online:
            Text("LIVE")
                .font(Theme.label(9)).tracking(1)
                .foregroundStyle(Theme.Palette.live)
        case .offline:
            Text("OFFLINE")
                .font(Theme.label(9)).tracking(1)
                .foregroundStyle(Theme.Palette.inkFaint)
        case .unknown:
            Text("PROBING")
                .font(Theme.label(9)).tracking(1)
                .foregroundStyle(Theme.Palette.inkFaint)
        }
    }
}

// MARK: - Card body with filtered @Query

private struct ServerCardBody: View {
    let server: Server
    let snapshot: ModelSnapshot?
    var onPin: ((String) -> Void)? = nil
    var onUnpin: ((String) -> Void)? = nil
    @Query private var records: [UsageRecord]

    init(server: Server, snapshot: ModelSnapshot?, onPin: ((String) -> Void)? = nil, onUnpin: ((String) -> Void)? = nil) {
        self.server = server
        self.snapshot = snapshot
        self.onPin = onPin
        self.onUnpin = onUnpin
        let label = server.label
        _records = Query(
            filter: #Predicate<UsageRecord> { $0.serverLabel == label },
            sort: \UsageRecord.timestamp, order: .reverse
        )
    }

    var body: some View {
        let rollup = InferenceRollup.compute(from: Array(records.prefix(20)).reversed())
        VStack(alignment: .leading, spacing: 12) {
            let loadedModels = snapshot?.models ?? []
            if loadedModels.isEmpty {
                NoModelRow()
            } else {
                ForEach(loadedModels, id: \.id) { model in
                    LoadedModelRow(
                        model: model,
                        onPin: onPin.map { cb in { cb(model.id) } },
                        onUnpin: onUnpin.map { cb in { cb(model.id) } }
                    )
                }
            }

            if rollup.requestCount > 0 {
                Divider().overlay(Theme.Palette.stroke)

                Eyebrow("All Models · Last \(rollup.requestCount) requests")

                // Each metric pairs its LAST/AVG/PEAK summary with a full-width
                // sparkline beneath it. Stacking vertically (rather than two
                // charts side-by-side) gives each chart the whole panel width, so
                // the recent requests spread out instead of cramming into half a row.
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        MetricStat(
                            label: "Tok/s",
                            last: rollup.lastTokPerSec.map { String(format: "%.0f", $0) },
                            avg:  rollup.avgTokPerSec.map  { String(format: "%.0f", $0) },
                            peak: rollup.peakTokPerSec.map { String(format: "%.0f", $0) }
                        )
                        ThroughputChart(values: rollup.tokPerSecHistory)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        MetricStat(
                            label: "TTFT (ms)",
                            last: rollup.lastTTFTms.map { "\($0)" },
                            avg:  rollup.avgTTFTms.map  { String(format: "%.0f", $0) },
                            peak: rollup.peakTTFTms.map { "\($0)" }
                        )
                        TTFTChart(values: rollup.ttftHistory)
                    }
                }
            }
        }
    }
}
