import XCTest
@testable import Modelo

final class LlamaSwapClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func client() -> LlamaSwapClient { LlamaSwapClient(session: StubURLProtocol.makeSession()) }
    private func swap() -> Endpoint { Endpoint(baseURL: "http://localhost:8080", kind: .llamaSwap, apiKey: nil) }

    func test_readyModelIDs_keepsOnlyReadyModels() async throws {
        let body = """
        {"running":[
          {"model":"qwen-coder","state":"ready","cmd":"","proxy":"","ttl":0,"name":"","description":""},
          {"model":"llama-70b","state":"starting","cmd":"","proxy":"","ttl":0,"name":"","description":""},
          {"model":"old","state":"stopping","cmd":"","proxy":"","ttl":0,"name":"","description":""}
        ]}
        """
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/running"))
            return (.stub(200), Data(body.utf8))
        }
        let ready = try await client().readyModelIDs(endpoint: swap())
        XCTAssertEqual(ready, ["qwen-coder"])
    }

    func test_readyModelIDs_emptyWhenNothingRunning() async throws {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"running":[]}"#.utf8)) }
        let ready = try await client().readyModelIDs(endpoint: swap())
        XCTAssertTrue(ready.isEmpty)
    }

    func test_unload_postsToPerModelRouteKeepingSlashes() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/api/models/unload/org/my model"
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
            return (.stub(200), Data("OK".utf8))
        }
        try await client().unload(modelID: "org/my model", endpoint: swap())
    }

    func test_unload_unknownModelThrowsServerError() async {
        StubURLProtocol.handler = { _ in (.stub(404), Data("model not found".utf8)) }
        do {
            try await client().unload(modelID: "nope", endpoint: swap())
            XCTFail("expected a 404 to throw")
        } catch let ClientError.serverError(message) {
            XCTAssertTrue(message.contains("404"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
