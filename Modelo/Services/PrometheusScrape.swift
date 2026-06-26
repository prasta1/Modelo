import Foundation

/// One parsed sample from the Prometheus text exposition format.
struct PromSample: Equatable {
    let name: String
    let labels: [String: String]
    let value: Double
}

/// Minimal parser for the Prometheus text exposition format (§2.3).
///
/// Handles the lines we care about: `metric_name{label="v",…} 1.23` and the
/// label-less `metric_name 1.23`. Skips `#` HELP/TYPE comments and blanks. This is a
/// pragmatic subset — enough to read vLLM / llama.cpp / llama-swap gauges and
/// counters — not a spec-complete implementation (no exemplars, no timestamps).
enum PrometheusParser {
    static func parse(_ text: String) -> [PromSample] {
        var samples: [PromSample] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Split metric (with optional {labels}) from the trailing value.
            guard let lastSpace = line.lastIndex(of: " ") else { continue }
            let metricPart = line[..<lastSpace].trimmingCharacters(in: .whitespaces)
            let valuePart = line[line.index(after: lastSpace)...].trimmingCharacters(in: .whitespaces)
            guard let value = Double(valuePart), value.isFinite else { continue }   // skip NaN/Inf/garbage (Double() accepts "nan"/"inf")

            let name: String
            let labels: [String: String]
            if let brace = metricPart.firstIndex(of: "{"), metricPart.hasSuffix("}") {
                name = String(metricPart[..<brace])
                let inner = metricPart[metricPart.index(after: brace)..<metricPart.index(before: metricPart.endIndex)]
                labels = parseLabels(String(inner))
            } else {
                name = metricPart
                labels = [:]
            }
            guard !name.isEmpty else { continue }
            samples.append(PromSample(name: name, labels: labels, value: value))
        }
        return samples
    }

    /// Parses `a="1",b="2"` into a dictionary. Tolerant of spaces; values are
    /// expected to be double-quoted per the format.
    private static func parseLabels(_ inner: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in inner.split(separator: ",") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            var val = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { labels[key] = val }
        }
        return labels
    }
}

/// The handful of server-wide metrics Modelo surfaces from a scrape. Each field is
/// optional — backends expose different subsets under different names, so we try a
/// list of known aliases (vLLM, llama.cpp/llama-swap) and keep whatever matched.
struct PrometheusSnapshot: Equatable {
    var requestsRunning: Double?
    var requestsWaiting: Double?
    var kvCachePct: Double?           // 0–100

    var isEmpty: Bool {
        requestsRunning == nil && requestsWaiting == nil && kvCachePct == nil
    }

    init(samples: [PromSample]) {
        func firstValue(_ names: [String]) -> Double? {
            for n in names { if let s = samples.first(where: { $0.name == n }) { return s.value } }
            return nil
        }
        requestsRunning = firstValue(["vllm:num_requests_running", "llamacpp:requests_processing"])
        requestsWaiting = firstValue(["vllm:num_requests_waiting", "llamacpp:requests_deferred"])
        // vLLM reports a 0–1 fraction; normalize to a percentage.
        if let frac = firstValue(["vllm:gpu_cache_usage_perc", "vllm:kv_cache_usage_perc"]) {
            kvCachePct = frac <= 1 ? frac * 100 : frac
        }
    }
}
