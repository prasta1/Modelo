import XCTest
@testable import Modelo

final class LMStudioClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    func makeClient() -> LMStudioClient {
        LMStudioClient(session: StubURLProtocol.makeSession())
    }

    private func lmStudio(_ base: String = "http://studio:1234") -> Endpoint {
        Endpoint(baseURL: base, kind: .lmStudio, apiKey: nil)
    }

    private func openRouter(key: String? = "sk-or-test") -> Endpoint {
        Endpoint(baseURL: "https://openrouter.ai/api/v1", kind: .openRouter, apiKey: key)
    }

    func test_fetchModels_parsesRichEndpoint() async throws {
        let body = #"{"data":[{"id":"qwen3-30b","object":"model","type":"llm","state":"loaded","max_context_length":32768}]}"#
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.contains("/api/v0/models"))
            return (.stub(200), Data(body.utf8))
        }
        let models = try await makeClient().fetchModels(endpoint: lmStudio())
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.id, "qwen3-30b")
        XCTAssertTrue(models.first?.isLoaded == true)
    }

    func test_fetchModels_filtersEmbeddingModels() async throws {
        let body = #"{"data":[{"id":"nomic-embed","object":"model","type":"embeddings"},{"id":"qwen3","object":"model","type":"llm"}]}"#
        StubURLProtocol.handler = { _ in (.stub(200), Data(body.utf8)) }
        let models = try await makeClient().fetchModels(endpoint: lmStudio())
        XCTAssertEqual(models.map(\.id), ["qwen3"])
    }

    func test_fetchModels_throwsUnreachableOnError() async {
        StubURLProtocol.handler = { _ in (.stub(500), Data()) }
        do {
            _ = try await makeClient().fetchModels(endpoint: lmStudio())
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? ClientError, .unreachable)
        }
    }

    func test_probeReachable_trueOn2xx() async {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"data":[]}"#.utf8)) }
        let ok = await makeClient().probeReachable(endpoint: lmStudio())
        XCTAssertTrue(ok)
    }

    func test_probeReachable_falseOnError() async {
        StubURLProtocol.handler = { _ in (.stub(500), Data()) }
        let ok = await makeClient().probeReachable(endpoint: lmStudio())
        XCTAssertFalse(ok)
    }

    func test_probeReachable_falseOnInvalidURL() async {
        let ok = await makeClient().probeReachable(endpoint: Endpoint(baseURL: "not a url", kind: .lmStudio, apiKey: nil))
        XCTAssertFalse(ok)
    }

    func test_fetchModels_openRouter_decodesCatalogAndSendsAuth() async throws {
        let body = #"{"data":[{"id":"a/b","context_length":4096,"pricing":{"prompt":"0","completion":"0"},"architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]}]}"#
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/api/v1/models"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "Modelo")
            return (.stub(200), Data(body.utf8))
        }
        let models = try await makeClient().fetchModels(endpoint: openRouter())
        XCTAssertEqual(models.map(\.id), ["a/b"])
        XCTAssertTrue(models.first?.supportsToolUse == true)
    }

    func test_fetchModels_lmStudio_sendsNoAuthHeader() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            return (.stub(200), Data(#"{"data":[{"id":"qwen3","object":"model","type":"llm"}]}"#.utf8))
        }
        _ = try await makeClient().fetchModels(endpoint: lmStudio())
    }

    func test_streamChat_assemblesToolCallsAcrossFragments() async throws {
        let sse = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search","arguments":"{\"q\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"cats\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n") + "\n\n"
        StubURLProtocol.handler = { _ in (.stub(200), Data(sse.utf8)) }

        let stream = makeClient().streamChat(
            endpoint: lmStudio(), modelID: "m", messages: [],
            systemPrompt: "", temperature: 0.7, tools: nil)
        var calls: [ToolCall] = []
        for try await event in stream { if case .toolCalls(let c) = event { calls = c } }

        XCTAssertEqual(calls, [ToolCall(id: "c1", name: "search", arguments: #"{"q":"cats"}"#)])
    }
}
