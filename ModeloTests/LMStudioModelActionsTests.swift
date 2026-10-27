import XCTest
@testable import Modelo

final class LMStudioModelActionsTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func client() -> LMStudioClient { LMStudioClient(session: StubURLProtocol.makeSession()) }
    private func studio() -> Endpoint { Endpoint(baseURL: "http://localhost:1234", kind: .lmStudio, apiKey: nil) }

    /// Current LM Studio: load goes to v1 and carries the capped context.
    func test_load_usesV1WithContextLength() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/api/v1/models/load"))
            return (.stub(200), Data(#"{"instance_id":"devstral"}"#.utf8))
        }
        try await client().loadModel(modelID: "devstral", contextLength: 65_536, endpoint: studio())

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "devstral")
        XCTAssertEqual(json["context_length"] as? Int, 65_536)
    }

    /// Older LM Studio has no v1 route (answers 200 + "Unexpected endpoint"): fall back to v0.
    func test_unload_fallsBackToV0WhenV1IsMissing() async throws {
        var paths: [String] = []
        StubURLProtocol.handler = { req in
            paths.append(req.url!.path)
            if req.url!.path.hasPrefix("/api/v1") {
                return (.stub(200), Data(#"{"error":"Unexpected endpoint or method. (POST /api/v1/models/unload)"}"#.utf8))
            }
            return (.stub(200), Data("{}".utf8))
        }
        try await client().unloadModel(modelID: "devstral", endpoint: studio())
        XCTAssertEqual(paths, ["/api/v1/models/unload", "/api/v0/models/devstral/unload"])
    }

    /// A real LM Studio error surfaces its message, not "couldn't reach the server".
    func test_load_surfacesLMStudioErrorMessage() async {
        StubURLProtocol.handler = { _ in
            (.stub(400), Data(#"{"error":{"message":"Model not found","type":"invalid_request"}}"#.utf8))
        }
        do {
            try await client().loadModel(modelID: "nope", contextLength: nil, endpoint: studio())
            XCTFail("expected an error")
        } catch let ClientError.serverError(message) {
            XCTAssertEqual(message, "Model not found")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Loaded below its maximum names both (so it can't read as usage); otherwise just the max.
    func test_contextDisplay_showsLoadedOfMax() throws {
        func model(_ json: String) throws -> LMStudioModel {
            try JSONDecoder().decode(LMStudioModel.self, from: Data(json.utf8))
        }
        let loaded = try model(#"{"id":"d","max_context_length":393216,"loaded_context_length":65536}"#)
        XCTAssertEqual(loaded.contextDisplay(), "65K loaded, 393K max")
        XCTAssertEqual(loaded.contextDisplay(compact: true), "65K / 393K max")
        XCTAssertNotNil(loaded.contextHelp)
        XCTAssertEqual(loaded.contextWindow, 65_536)
        XCTAssertEqual(try model(#"{"id":"d","max_context_length":393216}"#).contextDisplay(), "393K")
        XCTAssertNil(try model(#"{"id":"d"}"#).contextDisplay())
    }

    func test_contextLength_capsAtModelMaxAndHonorsLMStudioDefault() {
        XCTAssertEqual(LMStudioLoadContext.contextLength(cap: 65_536, modelMax: 393_216), 65_536)
        XCTAssertEqual(LMStudioLoadContext.contextLength(cap: 65_536, modelMax: 32_768), 32_768)
        XCTAssertEqual(LMStudioLoadContext.contextLength(cap: 65_536, modelMax: nil), 65_536)
        XCTAssertNil(LMStudioLoadContext.contextLength(cap: 0, modelMax: 393_216))
    }
}
