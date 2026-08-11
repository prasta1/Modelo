import Foundation
import Darwin

/// A server discovered on the local network.
struct DiscoveredHost: Identifiable, Equatable {
    let id: UUID
    let host: String
    let port: Int
    let kind: ServerKind

    init(host: String, port: Int, kind: ServerKind) {
        self.id = UUID()
        self.host = host
        self.port = port
        self.kind = kind
    }
}

/// Probes the local network for OpenAI-compatible LLM servers on all known default ports.
///
/// Scans localhost plus every host in each /24 subnet attached to the machine's
/// active non-loopback IPv4 interfaces. The candidate list is the cross-product of
/// hosts × known local ports (1234, 8000, 8080, 11434, 52415). Up to 40 probes run
/// concurrently; found hosts stream in as they respond so the UI can show results
/// immediately. Each found host is best-effort classified by kind.
@Observable
@MainActor
final class NetworkScanner {

    enum State: Equatable {
        case idle
        case scanning(progress: Double)
        case done
    }

    private(set) var state: State = .idle
    private(set) var found: [DiscoveredHost] = []

    private var scanTask: Task<Void, Never>?
    private let client: LMStudioClient

    init(client: LMStudioClient = .shared) {
        self.client = client
    }

    func scan() {
        scanTask?.cancel()
        found = []
        state = .scanning(progress: 0)

        // Cross-product of hosts × all known local default ports.
        let ports = Array(Set(ServerKind.localCases.map(\.defaultPort))).sorted()
        let hosts = buildCandidates()
        let candidates: [(String, Int)] = hosts.flatMap { h in ports.map { (h, $0) } }
        let total = max(1, candidates.count)
        // Capture client by value so child tasks don't inherit @MainActor isolation.
        let c = client

        scanTask = Task {
            var completed = 0
            await withTaskGroup(of: Optional<DiscoveredHost>.self) { group in
                let batchSize = min(40, candidates.count)
                var nextIdx = batchSize

                for i in 0..<batchSize {
                    let (host, port) = candidates[i]
                    group.addTask {
                        let baseURL = "http://\(host):\(port)"
                        let ep = Endpoint(baseURL: baseURL, kind: .lmStudio, apiKey: nil)
                        guard await c.probeReachable(endpoint: ep, timeout: 1.0) else { return nil }
                        let kind = await c.classifyKind(baseURL: baseURL, port: port)
                        return DiscoveredHost(host: host, port: port, kind: kind)
                    }
                }

                for await result in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    completed += 1
                    state = .scanning(progress: Double(completed) / Double(total))
                    if let discovered = result {
                        found.append(discovered)
                    }
                    if nextIdx < candidates.count {
                        let (host, port) = candidates[nextIdx]; nextIdx += 1
                        group.addTask {
                            let baseURL = "http://\(host):\(port)"
                            let ep = Endpoint(baseURL: baseURL, kind: .lmStudio, apiKey: nil)
                            guard await c.probeReachable(endpoint: ep, timeout: 1.0) else { return nil }
                            let kind = await c.classifyKind(baseURL: baseURL, port: port)
                            return DiscoveredHost(host: host, port: port, kind: kind)
                        }
                    }
                }
            }
            if !Task.isCancelled { state = .done }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    // MARK: - Private

    private func buildCandidates() -> [String] {
        var hosts = ["localhost"]
        for prefix in localSubnetPrefixes() {
            hosts += (1...254).map { "\(prefix).\($0)" }
        }
        return hosts
    }

    /// Returns the /24 prefix (e.g. "192.168.1") for each active
    /// non-loopback IPv4 interface attached to this machine.
    private func localSubnetPrefixes() -> [String] {
        var prefixes: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return prefixes }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard let rawAddr = ifa.pointee.ifa_addr,
                  rawAddr.pointee.sa_family == UInt8(AF_INET),
                  !name.hasPrefix("lo") else { continue }
            // Temporarily rebind sockaddr pointer to read it as sockaddr_in.
            let sin = rawAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var sinCopy = sin
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sinCopy.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            guard !ip.hasPrefix("169.254.") else { continue }   // skip link-local
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
                if !prefixes.contains(prefix) { prefixes.append(prefix) }
            }
        }
        return prefixes
    }
}
