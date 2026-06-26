import Foundation

/// A point-in-time GPU reading from a `modelo-tap` agent (`GET /gpu`).
///
/// Field names mirror the agent's JSON wire format (snake_case) via `CodingKeys`.
/// See `modelo-tap/README.md`. On unified-memory boxes (GB10/DGX Spark) the
/// top-level `vram*` comes from `/proc/meminfo`; per-device figures come from
/// `nvidia-smi`, with `[Not Supported]`/`[N/A]` parsed to `0` by the agent.
struct GPUSnapshot: Codable, Equatable, Sendable {
    var vramUsedGB: Double
    var vramTotalGB: Double
    var powerW: Double
    var powerLimitW: Double
    var tempC: Double
    var utilPct: Double
    var devices: [Device]

    struct Device: Codable, Equatable, Sendable {
        var name: String
        var utilPct: Double
        var memUsedGB: Double
        var memTotalGB: Double
        var tempC: Double
        var powerW: Double
        var powerLimitW: Double

        enum CodingKeys: String, CodingKey {
            case name
            case utilPct = "util_pct"
            case memUsedGB = "mem_used_gb"
            case memTotalGB = "mem_total_gb"
            case tempC = "temp_c"
            case powerW = "power_w"
            case powerLimitW = "power_limit_w"
        }
    }

    enum CodingKeys: String, CodingKey {
        case vramUsedGB = "vram_used_gb"
        case vramTotalGB = "vram_total_gb"
        case powerW = "power_w"
        case powerLimitW = "power_limit_w"
        case tempC = "temp_c"
        case utilPct = "util_pct"
        case devices
    }
}
