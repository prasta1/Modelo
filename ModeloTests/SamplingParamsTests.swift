import XCTest
@testable import Modelo

final class SamplingParamsTests: XCTestCase {
    /// A conversation override's non-nil fields win; nil fields fall through to the
    /// global defaults.
    func test_overlaying_prefersOwnNonNilFieldsThenBase() {
        let global = SamplingParams(temperature: 0.7, topP: 0.9, maxTokens: 2048)
        let override = SamplingParams(temperature: 0.2, maxTokens: nil, presencePenalty: 0.5)

        let result = override.overlaying(global)

        XCTAssertEqual(result.temperature, 0.2)     // override wins
        XCTAssertEqual(result.topP, 0.9)            // inherited from global
        XCTAssertEqual(result.maxTokens, 2048)      // nil override → global
        XCTAssertEqual(result.presencePenalty, 0.5) // only in override
        XCTAssertNil(result.frequencyPenalty)       // set in neither
    }

    func test_overlaying_emptyOverrideYieldsBase() {
        let global = SamplingParams(temperature: 0.7, topP: 0.95)
        XCTAssertEqual(SamplingParams().overlaying(global), global)
    }

    func test_codableRoundTrip() throws {
        let p = SamplingParams(temperature: 0.3, topP: 0.8, maxTokens: 512,
                               frequencyPenalty: 0.1, presencePenalty: -0.2, stop: ["END"])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(SamplingParams.self, from: data), p)
    }
}
