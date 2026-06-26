import Foundation

/// Parses a line of `macmon pipe` JSON into the shared `GPUSnapshot` (§2.2), so
/// Apple-Silicon local GPU stats render through the same Status/inspector tiles as
/// the remote `modelo-tap` agent. On Apple Silicon "VRAM" is unified memory, so we
/// map the system RAM figures into the VRAM fields.
enum Macmon {
    /// Common Homebrew install locations (the app's PATH when launched from Finder
    /// doesn't include these, so we resolve explicitly).
    static let candidatePaths = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"]

    static func resolvedPath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Maps one `macmon pipe` JSON sample to a `GPUSnapshot`. Returns nil for a line
    /// that isn't a decodable sample (e.g. a blank/partial line).
    static func parse(_ line: String) -> GPUSnapshot? {
        guard let data = line.data(using: .utf8),
              let s = try? JSONDecoder().decode(Sample.self, from: data) else { return nil }
        // gpu_usage is [frequency_MHz, usage_fraction]; take the fraction → percent.
        let util = (s.gpu_usage?.count ?? 0) >= 2 ? (s.gpu_usage?[1] ?? 0) * 100 : 0
        return GPUSnapshot(
            vramUsedGB: (s.memory?.ram_usage ?? 0) / 1_000_000_000,
            vramTotalGB: (s.memory?.ram_total ?? 0) / 1_000_000_000,
            powerW: s.gpu_power ?? 0,
            powerLimitW: 0,                       // macmon doesn't report a GPU power cap
            tempC: s.temp?.gpu_temp_avg ?? 0,
            utilPct: util,
            devices: []
        )
    }

    /// The subset of macmon's pipe JSON we read.
    private struct Sample: Decodable {
        let gpu_power: Double?
        let gpu_usage: [Double]?
        let temp: Temp?
        let memory: Mem?
        struct Temp: Decodable { let gpu_temp_avg: Double? }
        struct Mem: Decodable { let ram_total: Double?; let ram_usage: Double? }
    }
}
