import SwiftUI
import SwiftData

/// Per-server inference stats with a horizontal server pill strip at the top.
/// Clicking a pill selects that server; the dashboard below shows its live metrics
/// derived from `UsageRecord` history, `ServerRegistry`, and `ServerMonitor`.
struct ServerStatsView: View {
    @Binding var endpointFilter: UUID?
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor

    private var selectedServer: Server? {
        servers.first { $0.id == endpointFilter } ?? servers.first
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.windowBG.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                pillStrip
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                Divider().overlay(Theme.line)

                if let server = selectedServer {
                    ServerStatsDashboard(
                        server: server,
                        status: registry.status(for: server),
                        latency: registry.latency(for: server),
                        snapshot: monitor.snapshot(for: server)
                    )
                } else {
                    noServersState
                }
            }
        }
        .onAppear {
            if endpointFilter == nil, let first = servers.first {
                endpointFilter = first.id
            }
        }
    }

    // MARK: - Pill strip

    private var pillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(servers) { server in
                    ServerPill(
                        server: server,
                        status: registry.status(for: server),
                        isActive: endpointFilter == server.id
                    ) {
                        endpointFilter = server.id
                    }
                }
            }
        }
    }

    private var noServersState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("No servers configured.\nAdd one in Settings.")
                .font(.mono(11))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Server pill

private struct ServerPill: View {
    let server: Server
    let status: ServerStatus
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                StatusLED(status: status, size: 5)
                Text(server.label)
                    .font(Theme.label(9))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isActive ? Theme.amber : Theme.textDim)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive ? Theme.amberFill : (hovering ? Theme.fillHi : Color.clear),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Theme.amberBorder : Theme.line,
                    lineWidth: 1
                )
            )
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Data container (runs the per-server SwiftData query)

private struct ServerStatsDashboard: View {
    let server: Server
    let status: ServerStatus
    let latency: Double?
    let snapshot: ModelSnapshot?
    @Query private var records: [UsageRecord]

    init(server: Server, status: ServerStatus, latency: Double?, snapshot: ModelSnapshot?) {
        self.server = server
        self.status = status
        self.latency = latency
        self.snapshot = snapshot
        let label = server.label
        _records = Query(
            filter: #Predicate<UsageRecord> { $0.serverLabel == label },
            sort: \UsageRecord.timestamp, order: .reverse
        )
    }

    var body: some View {
        let rollup = InferenceRollup.compute(from: Array(records.prefix(20)).reversed())
        ServerStatsDashboardPanel(
            server: server,
            status: status,
            latency: latency,
            snapshot: snapshot,
            rollup: rollup
        )
    }
}

// MARK: - Dashboard panel

private struct ServerStatsDashboardPanel: View {
    let server: Server
    let status: ServerStatus
    let latency: Double?
    let snapshot: ModelSnapshot?
    let rollup: InferenceRollup
    @Environment(ReachabilityMonitor.self) private var reachabilityMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                metricTiles
                if rollup.requestCount > 0 {
                    inferenceStats
                } else {
                    noRequestsLabel
                }
                modelsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusLED(status: status, size: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                Text(hostSubtitle)
                    .font(.mono(10))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            statusBadge
            Button {
                Task { await reachabilityMonitor.checkOnce(server) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Retry \(server.label)")
        }
    }

    private var hostSubtitle: String {
        switch server.kind {
        case .lmStudio, .llamaCpp, .oMLX: return "\(server.host):\(server.port)"
        case .cloudAPI:   return URL(string: server.host)?.host ?? server.host
        case .openRouter: return "openrouter.ai"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .online:
            Text("LIVE")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.green)
        case .offline:
            Text("OFFLINE")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.textDim)
        case .unknown:
            Text("PROBING")
                .font(.mono(9)).tracking(1)
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: Metric tiles

    private var metricTiles: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                StatTile(label: "LATENCY",    value: latency.map { "\(Int($0)) ms" } ?? "—")
                StatTile(label: "MODELS",     value: snapshot.map { "\($0.models.count)" } ?? "—")
                StatTile(label: "REQUESTS",   value: rollup.requestCount > 0 ? "\(rollup.requestCount)" : "—")
                StatTile(label: "THROUGHPUT", value: rollup.avgTokPerSec.map { String(format: "%.0f t/s", $0) } ?? "—")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }

    // MARK: Inference stats

    private var inferenceStats: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                MetricStat(
                    label: "Decode Speed · tok/s",
                    last: rollup.lastTokPerSec.map { String(format: "%.0f", $0) },
                    avg:  rollup.avgTokPerSec.map  { String(format: "%.0f", $0) },
                    peak: rollup.peakTokPerSec.map { String(format: "%.0f", $0) }
                )
                if !rollup.tokPerSecHistory.isEmpty {
                    ThroughputChart(values: rollup.tokPerSecHistory)
                        .frame(height: 80)
                }
            }

            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 10) {
                MetricStat(
                    label: "Time to First Token · ms",
                    last: rollup.lastTTFTms.map { "\($0)" },
                    avg:  rollup.avgTTFTms.map  { String(format: "%.0f", $0) },
                    peak: rollup.peakTTFTms.map { "\($0)" }
                )
                if !rollup.ttftHistory.isEmpty {
                    TTFTChart(values: rollup.ttftHistory)
                        .frame(height: 80)
                }
            }

            Divider().overlay(Theme.line)

            HStack(spacing: 24) {
                miniStat("Requests",   value: "\(rollup.requestCount)")
                if let p = rollup.lastPromptTokens    { miniStat("Prefill",    value: "\(p)") }
                if let c = rollup.lastCompletionTokens { miniStat("Completion", value: "\(c)") }
            }
        }
    }

    private var noRequestsLabel: some View {
        Text("No requests this session")
            .font(.mono(11))
            .foregroundStyle(Theme.textFaint)
            .padding(.vertical, 4)
    }

    // MARK: Loaded models

    @ViewBuilder
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Loaded Models")
            if let models = snapshot?.models, !models.isEmpty {
                ForEach(models, id: \.id) { model in
                    LoadedModelRow(model: model)
                }
            } else if server.kind.isLocal {
                NoModelRow()
            } else {
                Text("Cloud endpoint — no live model snapshot")
                    .font(.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func miniStat(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading.uppercased())
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
            Text(value)
                .font(.mono(15))
                .foregroundStyle(Theme.textHi)
                .monospacedDigit()
        }
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.mono(9)).tracking(0.8)
                .foregroundStyle(Theme.textFaint)
            Text(value)
                .font(.mono(13.5))
                .foregroundStyle(Theme.textHi)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
