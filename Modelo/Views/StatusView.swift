import SwiftUI
import SwiftData

/// Full-page monitoring console — one card per LM Studio server.
/// All servers appear: offline cards are dimmed but present.
///
/// Native Refined look (handoff §6): cards over `Theme.windowBG`, design
/// typography, and amber telemetry. The content stays the detailed per-server
/// console (live loaded models + real Tok/s & TTFT rollups), re-skinned rather
/// than reduced to the mock's static 3-up summary cards.
struct StatusView: View {
    /// Called with (server, modelID) when the user pins a loaded model. nil hides the pin action.
    var onPin: ((Server, String) -> Void)? = nil
    /// Called with (server, modelID) when the user unpins a loaded model. nil hides the unpin action.
    var onUnpin: ((Server, String) -> Void)? = nil

    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    private var lmServers: [Server] { servers.filter { $0.kind == .lmStudio } }
    private var liveCount: Int { lmServers.filter { registry.isOnline($0) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVStack(spacing: 14) {
                    ForEach(lmServers) { server in
                        ServerConsoleCard(
                            server: server,
                            status: registry.status(for: server),
                            snapshot: monitor.snapshot(for: server),
                            onPin: onPin.map { cb in { modelID in cb(server, modelID) } },
                            onUnpin: onUnpin.map { cb in { modelID in cb(server, modelID) } }
                        )
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Theme.windowBG)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Server status")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textHi)
            Text("\(liveCount) of \(lmServers.count) live")
                .font(.mono(11))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
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
            Text(server.host)
                .font(.mono(10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .padding(.top, 6)
            Divider().overlay(Theme.line).padding(.vertical, 14)
            ServerCardBody(server: server, snapshot: snapshot, onPin: onPin, onUnpin: onUnpin)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.018),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
        .opacity(status == .offline ? 0.6 : 1)
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            StatusLED(status: status, size: 7)
            Text(server.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .lineLimit(1)
            Spacer(minLength: 0)
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .online:
            Text("LIVE")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.green)
        case .offline:
            Text("OFFLINE")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.textFaint)
        case .unknown:
            Text("PROBING")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.textDim)
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
                Divider().overlay(Theme.line)

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
