import XCTest
@testable import Modelo

final class OpenRouterCatalogTests: XCTestCase {
    private func models(_ json: String) throws -> [LMStudioModel] {
        try OpenRouterCatalog.models(from: Data(json.utf8))
    }

    func test_mapsCoreFields() throws {
        let json = #"""
        {"data":[{"id":"anthropic/claude-x","name":"Claude X","context_length":200000,
          "pricing":{"prompt":"0.000003","completion":"0.000015"},
          "architecture":{"input_modalities":["text","image"]},
          "supported_parameters":["tools","temperature"]}]}
        """#
        let m = try XCTUnwrap(models(json).first)
        XCTAssertEqual(m.id, "anthropic/claude-x")
        XCTAssertEqual(m.maxContextLength, 200000)
        XCTAssertFalse(m.isFree)
        XCTAssertTrue(m.supportsToolUse)   // authoritative from supported_parameters
        XCTAssertTrue(m.supportsVision)    // image in input_modalities -> type "vlm"
    }

    func test_freeByZeroPricing() throws {
        let json = #"{"data":[{"id":"x/y","context_length":8192,"pricing":{"prompt":"0","completion":"0"},"architecture":{"input_modalities":["text"]},"supported_parameters":[]}]}"#
        let m = try XCTUnwrap(models(json).first)
        XCTAssertTrue(m.isFree)
        XCTAssertFalse(m.supportsToolUse)  // empty supported_parameters -> false (not heuristic)
        XCTAssertFalse(m.supportsVision)
    }

    func test_freeBySuffix() throws {
        let json = #"{"data":[{"id":"meta/llama-3:free","context_length":8192,"pricing":{"prompt":"0.0001","completion":"0.0001"},"architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]}]}"#
        XCTAssertTrue(try XCTUnwrap(models(json).first).isFree)
    }

    func test_malformedEntryIsSkipped_notThrown() throws {
        // Missing required `id` on one entry -> that entry skipped, the valid one kept.
        let json = #"{"data":[{"context_length":1},{"id":"ok/model","context_length":4096,"pricing":{"prompt":"0","completion":"0"},"architecture":{"input_modalities":["text"]},"supported_parameters":[]}]}"#
        XCTAssertEqual(try models(json).map(\.id), ["ok/model"])
    }
}
