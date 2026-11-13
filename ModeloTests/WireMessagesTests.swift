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

    private func skillMessage(_ content: String) -> Message {
        let m = Message(role: .user, content: content)
        m.skillName = "brainstorming"
        m.skillInstructions = "Ask one question."
        return m
    }

    /// A skill-tagged turn sends the snapshotted instructions, then the user's text.
    func test_skillTaggedUser_expandsInstructionsThenText() {
        let wire = LMStudioClient.wireMessages([skillMessage("plan a deck")], systemPrompt: "")
        XCTAssertEqual(wire.map(\.role), ["user"])
        XCTAssertEqual(wire[0].content, .text("""
        Use the "brainstorming" skill. Its instructions:

        Ask one question.

        ---

        plan a deck
        """))
    }

    /// A bare `/skill` (no typed text) still reaches the model as the instructions.
    func test_bareSkill_sendsInstructionsOnly() {
        let wire = LMStudioClient.wireMessages([skillMessage("")], systemPrompt: "")
        XCTAssertEqual(wire.count, 1)
        guard case .text(let text)? = wire.first?.content else { return XCTFail("expected text") }
        XCTAssertTrue(text.hasSuffix("Ask one question."))
        XCTAssertFalse(text.contains("---"))
    }
}
