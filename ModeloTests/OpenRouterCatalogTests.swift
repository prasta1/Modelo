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

    // MARK: Prices ("how much for everything")

    func test_pricesConvertedToPerMillionTokens() throws {
        // Nous-style padded strings; per-token USD → per million.
        let json = #"{"data":[{"id":"p/particle-1","pricing":{"prompt":"0.0000002500","completion":"0.0000010000"}}]}"#
        let m = try XCTUnwrap(models(json).first)
        XCTAssertEqual(try XCTUnwrap(m.inputPricePerM), 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.outputPricePerM), 1.00, accuracy: 1e-9)
    }

    func test_missingPricing_leavesPricesNil() throws {
        let m = try XCTUnwrap(models(#"{"data":[{"id":"x/y"}]}"#).first)
        XCTAssertNil(m.inputPricePerM)
        XCTAssertNil(m.outputPricePerM)
    }

    /// Nous writes zero as "0.0000000000"; that must still count as free.
    func test_freeByPaddedZeroPricing() throws {
        let json = #"{"data":[{"id":"x/y","pricing":{"prompt":"0.0000000000","completion":"0.0000000000"}}]}"#
        XCTAssertTrue(try XCTUnwrap(models(json).first).isFree)
    }

    func test_freeVariant_getsEndDateAndPaidSiblingsPrices() throws {
        let json = #"""
        {"data":[
          {"id":"poolside/laguna-s-2.1:free","expiration_date":"2026-10-31","pricing":{"prompt":"0","completion":"0"}},
          {"id":"poolside/laguna-s-2.1","expiration_date":"2026-10-31","pricing":{"prompt":"0.0000004","completion":"0.0000016"}}
        ]}
        """#
        let all = try models(json)
        let free = try XCTUnwrap(all.first { $0.id.hasSuffix(":free") })
        XCTAssertEqual(free.freeUntil, ISO8601DateFormatter.dayUTC("2026-10-31"))
        XCTAssertEqual(try XCTUnwrap(free.normalInputPricePerM), 0.40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(free.normalOutputPricePerM), 1.60, accuracy: 1e-9)
        // A paid model's expiration_date is a retirement, not a promo end.
        XCTAssertNil(try XCTUnwrap(all.first { $0.id == "poolside/laguna-s-2.1" }).freeUntil)
    }
}

private extension ISO8601DateFormatter {
    static func dayUTC(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
