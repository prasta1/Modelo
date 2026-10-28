import XCTest
@testable import Modelo

final class AppleIntelligenceRequestTests: XCTestCase {
    private func user(_ s: String) -> WireMessage { WireMessage(role: "user", content: s) }
    private func assistant(_ s: String?) -> WireMessage { WireMessage(role: "assistant", content: s) }

    func test_make_mapsRoles() {
        let wire = [WireMessage(role: "system", content: "Be brief."), user("a"), assistant("b"), user("c")]
        let req = AppleIntelligenceRequest.make(from: wire, responseReserve: 1024)
        XCTAssertEqual(req?.instructions, "Be brief.")
        XCTAssertEqual(req?.history, [.user("a"), .assistant("b")])
        XCTAssertEqual(req?.prompt, "c")
        XCTAssertEqual(req?.droppedTurns, 0)
    }

    func test_make_skipsToolTraffic() {
        let toolCall = WireToolCall(id: "1", function: .init(name: "now", arguments: "{}"))
        let wire = [
            user("a"),
            WireMessage(role: "assistant", content: nil, toolCalls: [toolCall]),
            WireMessage(role: "tool", content: "12:00", toolCallID: "1"),
            assistant("It's noon."),
            user("thanks"),
        ]
        let req = AppleIntelligenceRequest.make(from: wire, responseReserve: 1024)
        XCTAssertEqual(req?.history, [.user("a"), .assistant("It's noon.")])
    }

    func test_make_keepsTextBlocksDropsImages() {
        let wire = [
            WireMessage(role: "user", blocks: [.text("hi"), .imageURL("data:image/png;base64,AAAA")]),
            assistant("hello"),
            WireMessage(role: "user", blocks: [.imageURL("data:image/png;base64,BBBB")]),
            assistant("nice picture"),
            user("bye"),
        ]
        let req = AppleIntelligenceRequest.make(from: wire, responseReserve: 1024)
        XCTAssertEqual(req?.history, [.user("hi"), .assistant("hello"), .assistant("nice picture")])
    }

    func test_make_trimsOldestFirst() {
        // Each turn is ~1,000 tokens (4 chars/token); the budget is 4096 - 1024 = 3072.
        let big = String(repeating: "x", count: 4000)
        let wire = [WireMessage(role: "system", content: "sys"),
                    user("1" + big), assistant("2" + big), user("3" + big), assistant("4" + big),
                    user("go")]
        let req = AppleIntelligenceRequest.make(from: wire, responseReserve: 1024)
        XCTAssertEqual(req?.instructions, "sys")
        XCTAssertEqual(req?.prompt, "go")
        XCTAssertEqual(req?.droppedTurns, 1)
        XCTAssertEqual(req?.history.count, 3)
        XCTAssertEqual(req?.history.first, .assistant("2" + big))
        let cost = TokenEstimator.estimate("sys") + TokenEstimator.estimate("go")
            + (req?.history ?? []).reduce(0) { total, turn in
                switch turn { case .user(let s), .assistant(let s): total + TokenEstimator.estimate(s) }
            }
        XCTAssertLessThanOrEqual(cost, AppleIntelligenceRequest.contextTokens - 1024)
    }

    func test_make_neverTrimsInstructionsOrPrompt() {
        let huge = String(repeating: "y", count: 20_000)
        let wire = [WireMessage(role: "system", content: huge), user("a"), assistant("b"), user(huge)]
        let req = AppleIntelligenceRequest.make(from: wire, responseReserve: 1024)
        XCTAssertEqual(req?.instructions, huge)
        XCTAssertEqual(req?.prompt, huge)
        XCTAssertEqual(req?.history, [])
        XCTAssertEqual(req?.droppedTurns, 2)
    }

    func test_make_nilWhenLastIsNotUser() {
        XCTAssertNil(AppleIntelligenceRequest.make(from: [user("a"), assistant("b")], responseReserve: 1024))
        XCTAssertNil(AppleIntelligenceRequest.make(from: [], responseReserve: 1024))
    }

    func test_delta() {
        XCTAssertEqual(AppleIntelligenceRequest.delta(from: "", to: "Hel"), "Hel")
        XCTAssertEqual(AppleIntelligenceRequest.delta(from: "Hel", to: "Hello"), "lo")
        XCTAssertEqual(AppleIntelligenceRequest.delta(from: "Hello", to: "Help"), "")
    }

    func test_generation() {
        XCTAssertEqual(AppleIntelligenceRequest.generation(SamplingParams()).temperature, 0.7)
        XCTAssertEqual(AppleIntelligenceRequest.generation(SamplingParams(temperature: 1.4)).temperature, 1.0)
        XCTAssertEqual(AppleIntelligenceRequest.generation(SamplingParams(temperature: -0.2)).temperature, 0.0)
        XCTAssertEqual(AppleIntelligenceRequest.generation(SamplingParams(maxTokens: 200)).maxTokens, 200)
        XCTAssertNil(AppleIntelligenceRequest.generation(SamplingParams()).maxTokens)
    }

    // MARK: AppleIntelligenceClient (availability depends on the machine, so these
    // assert shape and consistency, not a count)

    func test_models_shape() {
        let models = AppleIntelligenceClient.models()
        XCTAssertLessThanOrEqual(models.count, 1)
        if let m = models.first {
            XCTAssertEqual(m.id, "apple-on-device")
            XCTAssertTrue(m.isLoaded)
            XCTAssertEqual(m.isFree, true)
            XCTAssertEqual(m.toolUseSupported, false)
            XCTAssertEqual(m.maxContextLength, 4096)
        }
        XCTAssertEqual(models.isEmpty, !AppleIntelligenceClient.isAvailable())
    }

    func test_statusMessage_nilIffAvailable() {
        XCTAssertEqual(AppleIntelligenceClient.statusMessage() == nil, AppleIntelligenceClient.isAvailable())
    }
}
