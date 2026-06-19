import Foundation

enum ServerKind: Hashable {
    case lmStudio
    case cloud
}

/// An inference endpoint shown in the sidebar and grouped in the model picker.
/// Selection (the active server) is shared app state; live metrics stream in
/// separately (see `ServerStat`).
struct Server: Identifiable, Hashable {
    let id = UUID()
    var name: String            // "Mac Studio M3 Ultra"
    var host: String            // "studio.taile85139.ts.net:1234"
    var kind: ServerKind        // .lmStudio / .cloud
    var isLive: Bool = true

    /// Right-aligned label in the picker section header ("4 loaded" / "connected").
    var pickerMeta: String
}

/// Live monitoring frame for the Status dashboard. In the real app these values
/// arrive from `ServerMonitor` as an `AsyncStream`; the seeds here are sample
/// frames (handoff §6).
struct ServerStat: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var host: String
    var latency: String         // "12 ms"
    var models: String          // "4 loaded"
    var requests: String        // "38 / min"
    var throughput: String      // "42 tok/s"
    var spark: [Double]         // sparkline samples (0–100)
}
