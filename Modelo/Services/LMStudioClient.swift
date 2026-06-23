import Foundation

/// HTTP client for LM Studio's OpenAI-compatible API. The `URLSession` is
/// injected so tests can stub the network; production uses the default below.
final class LMStudioClient: ChatProvider {
    /// Shared instance for production. The client is stateless apart from its
    /// immutable `URLSession`, so one instance serves every server and avoids
    /// spinning up a separate `URLSession` per view.
    static let shared = LMStudioClient()

    private let session: URLSession

    /// Default session: no resource timeout (streams can run for minutes) but a
    /// per-request timeout so a dead server fails fast.
    init(session: URLSession = LMStudioClient.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Idle/inactivity timeout, reset on every byte received — NOT a total-duration
        // cap. It only fires during the gap before the first token, so a large value is
        // safe for long generations and never harms an active stream. It must tolerate
        // cold model loads: a llama-swap group with `exclusive: true` evicts the current
        // model and loads the requested GGUF from disk on first request, which can take
        // minutes. 300 matches the server's healthCheckTimeout; a lower value cancels the
        // request mid-load and the POST returns HTTP 200 with a 0-byte body.
        //
        // "Fail fast on a dead server" is the job of probeReachable(endpoint:timeout:)
        // (a 4s reachability probe), NOT this timeout — don't re-tighten it for that.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }

    // MARK: Models

    /// Prefers `/api/v0/models` (rich metadata); falls back to `/v1/models`.
    /// Embedding models are filtered out.
    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel] {
        switch endpoint.kind {
        case .cloudAPI:
            let data = try await authedGet(path: "/models", endpoint: endpoint)
            return try JSONDecoder().decode(ModelsResponse.self, from: data).data
                .filter { !$0.isEmbeddingModel }
        case .lmStudio:
            if let rich = try? await fetch(path: "/api/v0/models", endpoint: endpoint) {
                return rich.filter { !$0.isEmbeddingModel }
            }
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        case .llamaSwap:
            // llama.cpp / llama-swap is OpenAI-compatible but has no /api/v0.
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        }
    }

    /// GET with optional bearer auth; returns raw body.
    private func authedGet(path: String, endpoint: Endpoint) async throws -> Data {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(&request, endpoint: endpoint)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
        // A 401/403 means the server is up but wants (a different) API key — surface
        // that distinctly so the UI can reveal a key field, rather than "unreachable".
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ClientError.authRequired
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.unreachable }
        return data
    }

    /// Adds bearer auth whenever the endpoint carries a key — cloud APIs always, and
    /// local OpenAI-compatible servers (e.g. an MLX server) that require one.
    private func applyAuth(_ request: inout URLRequest, endpoint: Endpoint) {
        guard let key = endpoint.apiKey, !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func fetch(path: String, endpoint: Endpoint) async throws -> [LMStudioModel] {
        let data = try await authedGet(path: path, endpoint: endpoint)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data
    }

    /// Lightweight reachability check for `ReachabilityMonitor`: a single GET with a
    /// short per-request timeout. Returns true on a 2xx/3xx.
    /// Uses `/v1/models` for LM Studio (the standard OpenAI-compatible endpoint,
    /// present on all versions and compatible servers) rather than `/api/v0/models`
    /// (LM Studio-specific, absent on older builds and other local servers).
    func probeReachable(endpoint: Endpoint, timeout: TimeInterval = 4) async -> Bool {
        let path = endpoint.kind == .cloudAPI ? "/models" : "/v1/models"
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        applyAuth(&request, endpoint: endpoint)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    // MARK: Model load / unload (LM Studio only)

    /// Loads a model on an LM Studio server via `POST /api/v0/models/{id}/load`.
    /// Returns the updated model state if successful. No-op for OpenRouter.
    @discardableResult
    func loadModel(modelID: String, endpoint: Endpoint) async throws -> LMStudioModel {
        let data = try await postModelAction("load", modelID: modelID, endpoint: endpoint)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.first!
    }

    /// Unloads a model on an LM Studio server via `POST /api/v0/models/{id}/unload`.
    /// Returns the updated model state if successful. No-op for OpenRouter.
    @discardableResult
    func unloadModel(modelID: String, endpoint: Endpoint) async throws -> LMStudioModel {
        let data = try await postModelAction("unload", modelID: modelID, endpoint: endpoint)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.first!
    }

    /// Sets `keep_in_ram` on a loaded model via `POST /api/v0/models/{id}/load`.
    /// Pass `false` to unpin the model so LM Studio may evict it when loading another.
    func setKeepInRam(modelID: String, keepInRam: Bool, endpoint: Endpoint) async throws {
        _ = try await postModelAction("load", modelID: modelID, endpoint: endpoint,
                                      body: try JSONEncoder().encode(LoadModelBody(keep_in_ram: keepInRam)))
    }

    /// Shared `POST /api/v0/models/{id}/{verb}` for the load/unload/keep-in-ram actions
    /// (LM Studio only). Returns the response body.
    private func postModelAction(_ verb: String, modelID: String, endpoint: Endpoint,
                                 body: Data? = nil) async throws -> Data {
        guard endpoint.kind == .lmStudio else { throw ClientError.unsupported }
        let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "\(endpoint.baseURL)/api/v0/models/\(encoded)/\(verb)") else {
            throw ClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        applyAuth(&request, endpoint: endpoint)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.unreachable
        }
        return data
    }

    // MARK: Streaming chat

    func streamChat(
        endpoint: Endpoint,
        modelID: String,
        messages: [Message],
        systemPrompt: String,
        sampling: SamplingParams,
        tools: [ToolSpec]?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        // Snapshot the SwiftData-backed messages into Sendable value types on the
        // caller's actor (MainActor) BEFORE the network Task runs off the main
        // actor. Reading @Model properties (content / role / tool calls) off the
        // main actor is a data race — and a hard error under Swift 6 strict
        // concurrency. `wire`/`body` are plain value types, so the Task below
        // captures only Sendable data.
        var wire: [WireMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { wire.append(WireMessage(role: "system", content: sys)) }
        for m in messages {
            switch m.role {
            case .system:
                continue
            case .user:
                let imageAtts = m.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
                if imageAtts.isEmpty {
                    if !m.content.isEmpty { wire.append(WireMessage(role: "user", content: m.content)) }
                } else {
                    var blocks: [WireContentBlock] = []
                    if !m.content.isEmpty { blocks.append(.text(m.content)) }
                    for att in imageAtts { blocks.append(.imageURL(att.dataURL)) }
                    wire.append(WireMessage(role: "user", blocks: blocks))
                }
            case .assistant:
                if let json = m.toolCallsJSON, let calls = ToolCall.decodeList(json) {
                    wire.append(WireMessage(
                        role: "assistant",
                        content: m.content.isEmpty ? nil : m.content,
                        toolCalls: calls.map { WireToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments)) }))
                } else if !m.content.isEmpty {
                    wire.append(WireMessage(role: "assistant", content: m.content))
                }
            case .tool:
                wire.append(WireMessage(role: "tool", content: m.content, toolCallID: m.toolCallID))
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Try with include_usage first. Some Gemma models in LM Studio emit
                // "failed to resolve model metadata" when the tokenizer is needed for
                // usage counting but can't be loaded. If that happens before any
                // content arrives, retry silently without stream_options — the chat
                // succeeds, just without token-count telemetry for that turn.
                for includeUsage in [true, false] {
                    let body = ChatRequest(
                        model: modelID, messages: wire, tools: tools,
                        temperature: sampling.temperature ?? 0.7,
                        top_p: sampling.topP,
                        max_tokens: sampling.maxTokens,
                        frequency_penalty: sampling.frequencyPenalty,
                        presence_penalty: sampling.presencePenalty,
                        stop: sampling.stop,
                        stream: true,
                        stream_options: includeUsage ? StreamOptions(include_usage: true) : nil
                    )
                    let shouldRetry = await self.streamOnce(
                        body: body, endpoint: endpoint,
                        continuation: continuation, allowRetry: includeUsage
                    )
                    if !shouldRetry { return }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Executes one HTTP streaming attempt. Returns `true` when the caller should
    /// retry without `stream_options` (received a metadata-resolution error before
    /// any content was yielded), `false` in all other cases (success, cancellation,
    /// or a non-retriable error — the continuation is finished before returning).
    private func streamOnce(
        body: ChatRequest,
        endpoint: Endpoint,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        allowRetry: Bool
    ) async -> Bool {
        do {
            // LM Studio's base is host:port (needs /v1); cloud API bases already end in /v1.
            let chatPath = endpoint.kind == .cloudAPI ? "/chat/completions" : "/v1/chat/completions"
            guard let url = URL(string: "\(endpoint.baseURL)\(chatPath)") else {
                throw ClientError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(body)
            applyAuth(&request, endpoint: endpoint)

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
            guard (200..<300).contains(http.statusCode) else {
                // Read the error body to surface the actual message (e.g. model-specific
                // rejections from Gemma or other strict backends).
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count >= 4096 { break }
                }
                if let decoded = try? JSONDecoder().decode(HTTPErrorBody.self, from: errorData),
                   let msg = decoded.error?.message, !msg.isEmpty {
                    throw ClientError.serverError(msg)
                }
                throw ClientError.serverError("Server returned HTTP \(http.statusCode)")
            }

            var acc: [Int: (id: String, name: String, args: String)] = [:]
            var receivedContent = false

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let outcome: SSELineParser.Outcome
                do {
                    outcome = try SSELineParser.parse(line)
                } catch ClientError.serverError(let msg)
                    where allowRetry && !receivedContent && isMetadataResolutionError(msg) {
                    // Silently retry without usage tracking.
                    return true
                } catch {
                    continuation.finish(throwing: error)
                    return false
                }

                switch outcome {
                case .event(let e):
                    receivedContent = true
                    continuation.yield(e)
                case .toolCallDelta(let frags):
                    for f in frags {
                        var a = acc[f.index] ?? ("", "", "")
                        if let id = f.id { a.id = id }
                        if let n = f.name { a.name = n }
                        if let args = f.arguments { a.args += args }
                        acc[f.index] = a
                    }
                case .finish(let reason):
                    if reason == "tool_calls", !acc.isEmpty {
                        let calls = acc.keys.sorted().map {
                            ToolCall(id: acc[$0]!.id, name: acc[$0]!.name, arguments: acc[$0]!.args)
                        }
                        continuation.yield(.toolCalls(calls))
                    }
                case .done:
                    continuation.finish()
                    return false
                case .ignore:
                    continue
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        return false
    }

    private func isMetadataResolutionError(_ message: String) -> Bool {
        message.lowercased().contains("failed to resolve model metadata")
    }

    // MARK: Wire types
    private struct LoadModelBody: Encodable { let keep_in_ram: Bool }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let tools: [ToolSpec]?
        let temperature: Double
        // Optional sampling controls (§1.4); nil → omitted from JSON, so servers
        // that reject an unknown param never receive it.
        let top_p: Double?
        let max_tokens: Int?
        let frequency_penalty: Double?
        let presence_penalty: Double?
        let stop: [String]?
        let stream: Bool
        let stream_options: StreamOptions?   // nil → omitted from JSON
    }
    private struct StreamOptions: Encodable { let include_usage: Bool }

    private struct HTTPErrorBody: Decodable {
        let error: ErrorMsg?
        struct ErrorMsg: Decodable { let message: String? }
    }
}
