import Foundation

/// A placed exo model instance — the running entity that serves inference for a given model.
struct ExoInstance {
    let instanceID: String
    let modelID: String
}

/// HTTP client for exo's cluster management REST API.
///
/// Handles reading placed instances from `/state`, loading a model via `POST /instance`,
/// and unloading via `DELETE /instance/{id}`. The `URLSession` is injected so tests can stub the network.
final class ExoClient {
    private let session: URLSession

    init(session: URLSession = ExoClient.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// Returns all currently-placed model instances from exo's `/state` endpoint.
    func loadedInstances(endpoint: Endpoint) async throws -> [ExoInstance] {
        guard let url = URL(string: "\(endpoint.baseURL)/state") else { throw ClientError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.unreachable
        }
        let state = try JSONDecoder().decode(ExoStateResponse.self, from: data)
        return state.instances.compactMap { _, typeMap in
            guard let details = typeMap.values.first else { return nil }
            return ExoInstance(instanceID: details.instanceId, modelID: details.shardAssignments.modelId)
        }
    }

    /// Tells exo to place (load) a model by POSTing to `/instance`.
    func placeInstance(modelID: String, endpoint: Endpoint) async throws {
        guard let url = URL(string: "\(endpoint.baseURL)/instance") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model_id": modelID])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.unreachable
        }
    }

    /// Tells exo to unload a model instance via `DELETE /instance/{instanceID}`.
    func deleteInstance(instanceID: String, endpoint: Endpoint) async throws {
        guard let url = URL(string: "\(endpoint.baseURL)/instance/\(instanceID)") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.unreachable
        }
    }

    // MARK: - Wire types

    private struct ExoStateResponse: Decodable {
        /// Keyed by instance ID; the inner dict maps the instance type name to its details.
        let instances: [String: [String: InstanceDetails]]

        struct InstanceDetails: Decodable {
            let instanceId: String
            let shardAssignments: ShardAssignments

            struct ShardAssignments: Decodable {
                let modelId: String
            }
        }
    }
}
