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

    var body: some View {
        HStack(spacing: 10) {
            StatusLED(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.label)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(isEndpointActive ? Theme.Palette.signal : Theme.Palette.ink)
                Text(verbatim: "\(server.host):\(server.port)")
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
}
