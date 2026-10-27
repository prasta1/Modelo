import Foundation

/// Categorizes the failure mode of a reachability probe so the UI can surface
/// an actionable hint rather than a generic "offline" indicator.
enum ProbeResult {
    case reachable
    case hostNotFound    // DNS resolution failed
    case unreachable     // connection refused or non-2xx (host up, LM Studio not running)
    case timeout
    case invalidURL
}

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
        case .openRouter:
            let data = try await authedGet(path: "/models", endpoint: endpoint)
            return try OpenRouterCatalog.models(from: data)
                .filter { !$0.isEmbeddingModel }
        case .cloudAPI:
            let data = try await authedGet(path: "/models", endpoint: endpoint)
            return try JSONDecoder().decode(ModelsResponse.self, from: data).data
                .filter { !$0.isEmbeddingModel }
        case .nous:
            // Nous returns the OpenRouter `/models` schema — pricing, context_length,
            // supported_parameters, architecture — so decode it the same way.
            //
            // This previously used the plain OpenAI decode and force-set isFree on every
            // model, on the assumption that the endpoint carried no pricing. It does:
            // all 358 models price out, and the 5 free ones are marked both by a "0"
            // price and a `:free` suffix, which is exactly what OpenRouterCatalog reads.
            // The old path also lost maxContextLength (it looks for `max_context_length`;
            // Nous sends `context_length`) and the authoritative tool-use flag.
            let data = try await authedGet(path: "/models", endpoint: endpoint)
            return try OpenRouterCatalog.models(from: data)
                .filter { !$0.isEmbeddingModel }
        case .lmStudio:
            if let rich = try? await fetch(path: "/api/v0/models", endpoint: endpoint) {
                return rich.filter { !$0.isEmbeddingModel }
            }
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        case .llamaCpp, .llamaSwap, .oMLX:
            // Generic local OpenAI-compatible servers (llama.cpp, llama-swap, oMLX): no /api/v0.
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        case .exo:
            // exo's /v1/models is its full downloadable catalog; the downloaded-only
            // filter returns just the models present on the machine.
            return try await fetch(path: "/v1/models?status=downloaded", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        case .ollama:
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
        let path: String
        switch endpoint.kind {
        case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: path = "/v1/models"
        case .cloudAPI, .openRouter, .nous: path = "/models"
        }
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        applyAuth(&request, endpoint: endpoint)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    /// Best-effort server-kind fingerprint for a live local host.
    ///
    /// Assumes the host already answered GET /v1/models with a 2xx. Probes two
    /// distinguishing endpoints (LM Studio's `/api/v0/models`, exo's `/state`);
    /// falls back to port heuristics. llama.cpp and llama-swap are wire-identical —
    /// port 8080 is reported as `.llamaSwap`; users can override it in the row.
    func classifyKind(baseURL: String, port: Int) async -> ServerKind {
        if let url = URL(string: "\(baseURL)/api/v0/models") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            if let (_, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) {
                return .lmStudio
            }
        }
        if let url = URL(string: "\(baseURL)/state") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            if let (_, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) {
                return .exo
            }
        }
        switch port {
        case 11434: return .ollama
        case 52415: return .exo
        case 8000:  return .oMLX
        case 8080:  return .llamaSwap
        default:    return .lmStudio
        }
    }

    /// Like `probeReachable` but returns a `ProbeResult` identifying the failure
    /// mode so the settings UI can show an actionable hint (e.g. "hostname not
    /// found" versus "LM Studio not running on this port").
    func probeDetailed(endpoint: Endpoint, timeout: TimeInterval = 4) async -> ProbeResult {
        let path: String
        switch endpoint.kind {
        case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: path = "/v1/models"
        case .cloudAPI, .openRouter, .nous: path = "/models"
        }
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { return .invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        applyAuth(&request, endpoint: endpoint)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return (200..<400).contains(http.statusCode) ? .reachable : .unreachable
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return .hostNotFound
            case .timedOut:
                return .timeout
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    // MARK: Model load / unload (LM Studio only)

    /// Loads a model on an LM Studio server via `POST /api/v1/models/load`, falling back
    /// to the legacy `POST /api/v0/models/{id}/load` on versions without the v1 API.
    ///
    /// - Parameters:
    ///   - modelID: The model key to load.
    ///   - contextLength: Context to load with; nil leaves it to LM Studio's own default.
    ///     Only the v1 route accepts it, so older versions ignore it.
    ///   - endpoint: The LM Studio server.
    func loadModel(modelID: String, contextLength: Int?, endpoint: Endpoint) async throws {
        try await modelAction(v1Path: "/api/v1/models/load",
                              v1Body: LoadBodyV1(model: modelID, context_length: contextLength),
                              v0Verb: "load", modelID: modelID, endpoint: endpoint)
    }

    /// Unloads a model on an LM Studio server via `POST /api/v1/models/unload`, falling
    /// back to the legacy `POST /api/v0/models/{id}/unload`.
    ///
    /// - Parameters:
    ///   - modelID: The model key. A default (single or JIT) load's instance id is the
    ///     key itself, which is what v1 asks for.
    ///   - endpoint: The LM Studio server.
    func unloadModel(modelID: String, endpoint: Endpoint) async throws {
        try await modelAction(v1Path: "/api/v1/models/unload",
                              v1Body: UnloadBodyV1(instance_id: modelID),
                              v0Verb: "unload", modelID: modelID, endpoint: endpoint)
    }

    /// Sets `keep_in_ram` on a loaded model via `POST /api/v0/models/{id}/load`.
    /// Pass `false` to unpin the model so LM Studio may evict it when loading another.
    /// v1 has no equivalent, so this throws on LM Studio versions that dropped v0.
    func setKeepInRam(modelID: String, keepInRam: Bool, endpoint: Endpoint) async throws {
        guard endpoint.kind == .lmStudio else { throw ClientError.unsupported }
        let found = try await postModelRoute(Self.v0Path(modelID, "load"),
                                             body: try JSONEncoder().encode(LoadModelBody(keep_in_ram: keepInRam)),
                                             endpoint: endpoint)
        if !found { throw ClientError.serverError("This LM Studio version doesn't support Keep in RAM.") }
    }

    /// Runs a load/unload, trying the v1 route first and the v0 one if the server
    /// doesn't have v1 (LM Studio before the v1 API; newer versions dropped v0).
    private func modelAction<Body: Encodable>(v1Path: String, v1Body: Body, v0Verb: String,
                                              modelID: String, endpoint: Endpoint) async throws {
        guard endpoint.kind == .lmStudio else { throw ClientError.unsupported }
        if try await postModelRoute(v1Path, body: try JSONEncoder().encode(v1Body), endpoint: endpoint) { return }
        if try await postModelRoute(Self.v0Path(modelID, v0Verb), body: nil, endpoint: endpoint) { return }
        throw ClientError.serverError("This LM Studio version has no \(v0Verb) API.")
    }

    private static func v0Path(_ modelID: String, _ verb: String) -> String {
        let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        return "/api/v0/models/\(encoded)/\(verb)"
    }

    /// POSTs to an LM Studio model-management route.
    ///
    /// - Returns: `false` when the server doesn't have this route, so the caller can try
    ///   another; `true` on success.
    /// - Throws: LM Studio's own error message for any other failure, so the UI says
    ///   what went wrong instead of "couldn't reach the server".
    private func postModelRoute(_ path: String, body: Data?, endpoint: Endpoint) async throws -> Bool {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        applyAuth(&request, endpoint: endpoint)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
        if http.statusCode == 401 || http.statusCode == 403 { throw ClientError.authRequired }
        let message = Self.lmStudioErrorMessage(in: data)
        // LM Studio answers an unknown route with HTTP 200 and an error body, not a 404.
        if http.statusCode == 404 || message?.hasPrefix("Unexpected endpoint") == true { return false }
        if let message { throw ClientError.serverError(message) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.serverError("LM Studio returned HTTP \(http.statusCode)")
        }
        return true
    }

    /// LM Studio's error text from a response body — `{"error": "…"}` (unknown route) or
    /// `{"error": {"message": "…"}}` (v1). nil when the body carries no error.
    static func lmStudioErrorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] else { return nil }
        if let text = error as? String { return text }
        return (error as? [String: Any])?["message"] as? String
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
        let wire = Self.wireMessages(messages, systemPrompt: systemPrompt)

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

    /// Converts the conversation's active path into OpenAI-style wire messages,
    /// with the system prompt first.
    ///
    /// Consecutive user turns are folded into one. A failed or stopped reply drops
    /// its empty assistant message, so the next send would otherwise put two user
    /// turns back to back — and strict chat templates (Mistral/Devstral, Gemma)
    /// reject that with a 500 on every later send, bricking the chat.
    ///
    /// - Parameters:
    ///   - messages: The active path, oldest first. `.system` entries are skipped;
    ///     the system prompt is passed separately.
    ///   - systemPrompt: Sent as the leading system message when non-blank.
    /// - Returns: The messages to send, in order.
    static func wireMessages(_ messages: [Message], systemPrompt: String) -> [WireMessage] {
        var wire: [WireMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { wire.append(WireMessage(role: "system", content: sys)) }

        func appendUser(_ msg: WireMessage) {
            guard let last = wire.last, last.role == "user",
                  let prev = last.content, let next = msg.content else {
                wire.append(msg)
                return
            }
            if case .text(let a) = prev, case .text(let b) = next {
                wire[wire.count - 1] = WireMessage(role: "user", content: a + "\n\n" + b)
            } else {
                wire[wire.count - 1] = WireMessage(role: "user", blocks: prev.blocks + next.blocks)
            }
        }

        for m in messages {
            switch m.role {
            case .system:
                continue
            case .user:
                let allAtts = m.attachmentsJSON.flatMap { MessageAttachment.decodeList($0) } ?? []
                let imageAtts = allAtts.filter { $0.isImage }
                let textAtts  = allAtts.filter { !$0.isImage }

                if allAtts.isEmpty {
                    if !m.content.isEmpty { appendUser(WireMessage(role: "user", content: m.content)) }
                } else {
                    var blocks: [WireContentBlock] = []
                    // Text file attachments come first, each as a labeled fenced block.
                    for att in textAtts {
                        let text = String(data: att.data, encoding: .utf8) ?? "[unreadable]"
                        let safeName = att.fileName.replacingOccurrences(of: "\"", with: "\\\"")
                        blocks.append(.text("<file name=\"\(safeName)\">\n\(text)\n</file>"))
                    }
                    // User's typed message (may be empty if they attached without typing).
                    if !m.content.isEmpty { blocks.append(.text(m.content)) }
                    // Image attachments last (vision models only).
                    for att in imageAtts { blocks.append(.imageURL(att.dataURL)) }
                    appendUser(WireMessage(role: "user", blocks: blocks))
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

        return wire
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
            // LM Studio's base is host:port (needs /v1); llama.cpp/llama-swap and oMLX also need /v1.
            // Cloud API bases already end in /v1.
            let chatPath: String
            switch endpoint.kind {
            case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .exo: chatPath = "/v1/chat/completions"
            case .cloudAPI, .openRouter, .nous: chatPath = "/chat/completions"
            case .ollama: chatPath = "/v1/chat/completions"
            }
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
                // Classify auth the way the GET path above does, so an expired or
                // revoked key surfaces as "needs an API key" instead of whatever the
                // provider happens to call it — OpenRouter answers a bad key with
                // "User not found.", which reads like a model error, not a key one.
                // Deliberately 401/403 only: OpenRouter uses 402 for exhausted
                // credits, whose real message is worth passing through.
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw ClientError.authRequired
                }
                // Read the error body to surface the actual message (e.g. model-specific
                // rejections from Gemma or other strict backends).
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count >= 4096 { break }
                }
                // Gemini's OpenAI-compatible endpoint wraps the error in an array.
                let decoded = (try? JSONDecoder().decode(HTTPErrorBody.self, from: errorData))
                    ?? (try? JSONDecoder().decode([HTTPErrorBody].self, from: errorData))?.first
                if let msg = decoded?.error?.message, !msg.isEmpty {
                    throw ClientError.serverError(msg)
                }
                if http.statusCode == 429 {
                    let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                        .map { "try again in \($0)s" } ?? "try again shortly"
                    throw ClientError.serverError("Rate limited by the provider — \(wait).")
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
    /// nil `context_length` is omitted from the JSON, leaving it to LM Studio.
    private struct LoadBodyV1: Encodable { let model: String; let context_length: Int? }
    private struct UnloadBodyV1: Encodable { let instance_id: String }

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

/// How much context Modelo asks LM Studio for when it loads a model (Settings ▸ Endpoints).
///
/// LM Studio's own default can be "model maximum", which loads e.g. Devstral Small 2 at
/// its declared 393K and runs a 64 GB Mac's GPU out of memory on the first message.
// ponytail: one global cap; add a per-model override if a model ever needs more than it.
enum LMStudioLoadContext {
    static let key = "lmStudioLoadContextCap"
    /// 64K: a ~24B Q4 model plus its KV cache fits comfortably in 64 GB.
    static let defaultCap = 65_536
    /// Picker choices. 0 means "send nothing — use LM Studio's default".
    static let options = [0, 32_768, 65_536, 131_072]

    /// The `context_length` to request: the cap, but never more than the model supports.
    ///
    /// - Parameters:
    ///   - cap: The chosen cap; 0 means don't send one.
    ///   - modelMax: The model's declared maximum, when known.
    /// - Returns: The context to send, or nil to leave it to LM Studio.
    static func contextLength(cap: Int, modelMax: Int?) -> Int? {
        guard cap > 0 else { return nil }
        return min(cap, modelMax ?? cap)
    }

    /// `contextLength(cap:modelMax:)` for `model` using the cap saved in Settings.
    static func contextLength(for model: LMStudioModel) -> Int? {
        let cap = UserDefaults.standard.object(forKey: key) as? Int ?? defaultCap
        return contextLength(cap: cap, modelMax: model.maxContextLength)
    }
}
