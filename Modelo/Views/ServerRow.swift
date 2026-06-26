import SwiftUI

/// One server as a "channel strip": a glowing reachability LED, the machine label,
/// and its address in monospace. Offline machines dim back.
struct ServerRow: View {
    let server: Server
    let status: ServerStatus
    var isEndpointActive: Bool = false

    /// Spoken status so the color-only LED isn't lost to VoiceOver.
    private var statusLabel: String {
        switch status {
        case .online:  "online"
        case .offline: "offline"
        case .unknown: "status unknown"
        }
    }

    /// Human-readable subtitle for the server's connection method.
    /// Uses the user-supplied ID when set; otherwise auto-detects from host/kind.
    private var subtitle: String {
        if !server.connectionID.isEmpty { return server.connectionID }
        switch server.kind {
        case .openRouter:
            return "via API"
        case .lmStudio, .llamaSwap:
            return isTailscaleHost(server.host) ? "via Tailscale" : "\(server.host):\(server.port)"
        case .cloudAPI:
            return server.host
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusLED(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.label)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(isEndpointActive ? Theme.Palette.signal : Theme.Palette.ink)
                Text(verbatim: subtitle)
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.Palette.inkFaint)
            }
            Spacer(minLength: 0)
            if isEndpointActive {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.signal.opacity(0.7))
            }
        }
        .padding(.vertical, 2)
        .opacity(status == .offline ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.label), \(statusLabel)")
    }

    /// Returns true if the host looks like a Tailscale address —
    /// either a 100.64–127.x.x.x CGNAT IP or a .ts.net hostname.
    private func isTailscaleHost(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".")
        guard parts.count >= 2, parts[0] == "100", let second = Int(parts[1]) else { return false }
        return second >= 64 && second <= 127
    }
}
