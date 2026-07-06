import XCTest
@testable import Modelo

final class ExoClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func client() -> ExoClient { ExoClient(session: StubURLProtocol.makeSession()) }
    private func exo() -> Endpoint { Endpoint(baseURL: "http://localhost:52415", kind: .exo, apiKey: nil) }

    func test_loadedInstances_decodesWrappedCamelCase() async throws {
        let body = """
        {"instances":{"959b7da3":{"MlxRingInstance":{"instanceId":"959b7da3",
        "shardAssignments":{"modelId":"lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit"}}}}}
        """
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/state"))
            return (.stub(200), Data(body.utf8))
        }
        let loaded = try await client().loadedInstances(endpoint: exo())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.instanceID, "959b7da3")
        XCTAssertEqual(loaded.first?.modelID, "lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit")
    }

    func test_loadedInstances_emptyWhenNoInstances() async throws {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"instances":{}}"#.utf8)) }
        let loaded = try await client().loadedInstances(endpoint: exo())
        XCTAssertTrue(loaded.isEmpty)
    }

    func test_placeInstance_postsModelIdWithDefaults() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/place_instance"))
            return (.stub(200), Data(#"{"message":"Command received."}"#.utf8))
        }
        try await client().placeInstance(modelID: "org/model-4bit", endpoint: exo())
        let sent = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
        XCTAssertEqual(json["model_id"] as? String, "org/model-4bit")
        XCTAssertEqual(json["sharding"] as? String, "Pipeline")
        XCTAssertEqual(json["instance_meta"] as? String, "MlxRing")
        XCTAssertEqual(json["min_nodes"] as? Int, 1)
    }

    func test_deleteInstance_sendsDeleteToInstancePath() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/instance/959b7da3"))
            return (.stub(200), Data(#"{"message":"deleted"}"#.utf8))
        }
        try await client().deleteInstance(instanceID: "959b7da3", endpoint: exo())
    }

    func test_loadedInstances_throwsOnNon2xx() async {
        StubURLProtocol.handler = { _ in (.stub(503), Data()) }
        do {
            _ = try await client().loadedInstances(endpoint: exo())
            XCTFail("expected loadedInstances to throw on 503")
        } catch {
            // expected
        }
    }
}
