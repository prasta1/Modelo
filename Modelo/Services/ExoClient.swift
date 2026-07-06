import Foundation

/// Errors from exo's cluster API. Top-level (like `ClientError`) so load/unload
/// call sites can show an actionable reason.
enum ExoError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int)
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidURL:              "Invalid exo server URL."
        case .requestFailed(let code): "exo returned HTTP \(code)."
        case .networkFailure:          "Could not reach the exo server."
        }
    }
}

/// A loaded exo instance: which model it serves and the instance id to unload it.
struct ExoLoadedInstance: Equatable {
    let instanceID: String
    let modelID: String
}

/// Minimal client for exo's cluster API. Kept separate from `LMStudioClient`
/// because exo's `/state` and instance payloads are camelCase with variant
/// wrapper keys (e.g. `MlxRingInstance`) — a different wire contract.
final class ExoClient {
    private let session: URLSession
    init(session: URLSession = LMStudioClient.defaultSession()) { self.session = session }

    /// Models that currently have a placed (loaded) instance in exo.
    func loadedInstances(endpoint: Endpoint) async throws -> [ExoLoadedInstance] {
        let data = try await send("GET", "/state", endpoint: endpoint)
        let state = try JSONDecoder().decode(ExoState.self, from: data)
        return state.instances.values.compactMap { inst in
            guard let modelID = inst.modelID, let instanceID = inst.instanceID else { return nil }
            return ExoLoadedInstance(instanceID: instanceID, modelID: modelID)
        }
    }

    /// Place (load) a model as a single-node pipeline instance.
    func placeInstance(modelID: String, endpoint: Endpoint) async throws {
        let body = try JSONEncoder().encode(PlaceInstanceRequest(modelID: modelID))
        _ = try await send("POST", "/place_instance", endpoint: endpoint, body: body)
    }

    /// Delete (unload) a placed instance by its id.
    func deleteInstance(instanceID: String, endpoint: Endpoint) async throws {
        let encoded = instanceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? instanceID
        _ = try await send("DELETE", "/instance/\(encoded)", endpoint: endpoint)
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, endpoint: Endpoint,
                      body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { throw ExoError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ExoError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else { throw ExoError.networkFailure }
        guard (200..<300).contains(http.statusCode) else {
            throw ExoError.requestFailed(statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - Wire types

/// exo `/place_instance` request. exo expects snake_case; single-node pipeline defaults.
private struct PlaceInstanceRequest: Encodable {
    let modelID: String
    let sharding = "Pipeline"
    let instanceMeta = "MlxRing"
    let minNodes = 1
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case sharding
        case instanceMeta = "instance_meta"
        case minNodes = "min_nodes"
    }
}

/// exo `/state` — we only decode the instances map.
private struct ExoState: Decodable {
    let instances: [String: ExoInstance]
}

/// An instance is wrapped in a variant key (e.g. "MlxRingInstance"); we probe the
/// first wrapper value for `instanceId` + `shardAssignments.modelId`.
private struct ExoInstance: Decodable {
    let instanceID: String?
    let modelID: String?

    private struct Body: Decodable {
        let instanceId: String?
        let shardAssignments: ShardAssignments?
        struct ShardAssignments: Decodable { let modelId: String? }
    }
    private struct DynamicKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            if let body = try? container.decode(Body.self, forKey: key) {
                instanceID = body.instanceId
                modelID = body.shardAssignments?.modelId
                return
            }
        }
        instanceID = nil; modelID = nil
    }
}
