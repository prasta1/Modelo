import SwiftUI
import SwiftData
import Charts

/// Server Status dashboard (handoff §6): a responsive grid of compact live
/// server cards over `Theme.windowBG`. Each card shows reachability, the loaded-
/// model count, and real usage metrics (requests / tok-s / TTFT) from the
/// per-server `UsageRecord` rollup, plus an amber throughput sparkline.
///
/// Both LM Studio machines and the OpenRouter cloud endpoint appear. `LATENCY` is
/// the last reachability-probe round-trip from `ServerRegistry`; `MODELS` is blank
/// for OpenRouter, which isn't polled for a loaded-model snapshot.
struct StatusView: View {
    /// Called with (server, modelID) when the user pins a loaded model. Retained
    /// for API parity with the launcher/picker; the compact card has no pin UI.
    var onPin: ((Server, String) -> Void)? = nil
    var onUnpin: ((Server, String) -> Void)? = nil

    @Environment(ServerRegistry.self) private var registry
    @Environment(ServerMonitor.self) private var monitor
    @Query(sort: \Server.sortOrder) private var servers: [Server]

    private var liveCount: Int { servers.filter { registry.isOnline($0) }.count }

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(servers) { server in
                        CompactServerCard(
                            server: server,
                            status: registry.status(for: server),
                            latency: registry.latency(for: server),
                            snapshot: monitor.snapshot(for: server)
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
            Text("\(liveCount) of \(servers.count) live")
                .font(.mono(11))
                .foregroundStyle(Theme.textDim)
            Spacer()
        }
    }
}

// MARK: - Compact server card

private struct CompactServerCard: View {
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
        let modelCount = snapshot?.models.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                StatusLED(status: status, size: 7)
                Text(server.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Spacer(minLength: 0)
                statusLabel
            }
            Text(server.kind == .openRouter ? "openrouter.ai" : server.host)
                .font(.mono(10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .padding(.top, 8)

            Divider().overlay(Theme.line).padding(.vertical, 14)

            Grid(horizontalSpacing: 10, verticalSpacing: 13) {
                GridRow {
                    MetricTile(label: "LATENCY", value: latency.map { "\(Int($0)) ms" } ?? "—")
                    MetricTile(label: "MODELS",  value: modelCount.map { "\($0)" } ?? "—")
                }
                GridRow {
                    MetricTile(label: "REQUESTS",   value: rollup.requestCount > 0 ? "\(rollup.requestCount)" : "—")
                    MetricTile(label: "THROUGHPUT", value: rollup.avgTokPerSec.map { String(format: "%.0f t/s", $0) } ?? "—")
                }
            }

            if !rollup.tokPerSecHistory.isEmpty {
                Sparkline(values: rollup.tokPerSecHistory)
                    .frame(height: 28)
                    .padding(.top, 16)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.018),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
        .opacity(status == .offline ? 0.6 : 1)
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

// MARK: - Metric tile + sparkline

/// A single labelled metric in the Status card's 2×2 grid (MODELS / REQUESTS /
/// TOK/S / TTFT).
private struct MetricTile: View {
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

/// Tiny amber bar sparkline (handoff §6 — Swift Charts, axes hidden).
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            BarMark(
                x: .value("i", i),
                y: .value("v", v),
                width: .ratio(0.7)
            )
            .foregroundStyle(Theme.amber.opacity(0.42))
            .cornerRadius(1)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
