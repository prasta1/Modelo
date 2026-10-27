import XCTest
@testable import Modelo

@MainActor
final class WireMessagesTests: XCTestCase {
    /// A failed reply drops its empty assistant, leaving two user turns in a row.
    /// Strict templates (Devstral) 500 on that, so they must reach the wire as one.
    func test_consecutiveUserTurns_areMergedIntoOne() {
        let wire = LMStudioClient.wireMessages(
            [Message(role: .user, content: "first"),
             Message(role: .user, content: "second")],
            systemPrompt: "sys")

        XCTAssertEqual(wire.map(\.role), ["system", "user"])
        XCTAssertEqual(wire[1].content, .text("first\n\nsecond"))
    }

    /// Normal alternation is left untouched.
    func test_alternatingTurns_areUnchanged() {
        let wire = LMStudioClient.wireMessages(
            [Message(role: .user, content: "hi"),
             Message(role: .assistant, content: "hello"),
             Message(role: .user, content: "again")],
            systemPrompt: "")

        XCTAssertEqual(wire.map(\.role), ["user", "assistant", "user"])
    }
}
