import Foundation

/// HTTP client for llama-swap's management API: which models are up, and unloading one.
///
/// Routes, checked against llama-swap v264: `GET /running` and
/// `POST /api/models/unload/{model}`. Older releases only have `GET /unload`, which
/// unloads everything, so per-model unload can 404 there. The `URLSession` is injected so
/// tests can stub the network.
final class LlamaSwapClient {
    private let session: URLSession

    init(session: URLSession = LlamaSwapClient.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// IDs of models llama-swap has up and serving (`state == "ready"`). Models still
    /// starting or stopping are left out so the picker doesn't offer an eject mid-transition.
    func readyModelIDs(endpoint: Endpoint) async throws -> Set<String> {
        let data = try await send("GET", path: "/running", endpoint: endpoint)
        let decoded = try JSONDecoder().decode(RunningResponse.self, from: data)
        return Set(decoded.running.filter { $0.state == "ready" }.map(\.model))
    }

    /// Stops one model's process via `POST /api/models/unload/{model}`. The route takes the
    /// config model ID (or an alias); IDs containing `/` pass through as path segments.
    func unload(modelID: String, endpoint: Endpoint) async throws {
        let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        _ = try await send("POST", path: "/api/models/unload/\(encoded)", endpoint: endpoint)
    }

    private func send(_ method: String, path: String, endpoint: Endpoint) async throws -> Data {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let key = endpoint.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
        Log.network.info("llama-swap \(method, privacy: .public) \(url.path, privacy: .public) -> \(http.statusCode)")
        if http.statusCode == 404 {
            throw ClientError.serverError(
                "llama-swap returned 404: the model isn't in its config, or this version can't unload a single model.")
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.unreachable }
        return data
    }

    // MARK: - Wire types

    private struct RunningResponse: Decodable {
        let running: [Running]

        struct Running: Decodable {
            let model: String
            let state: String
        }
    }
}
