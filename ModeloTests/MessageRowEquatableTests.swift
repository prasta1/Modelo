import XCTest
@testable import Modelo

/// While a reply streams, the transcript re-renders ~20×/s and rebuilds every row with
/// fresh action closures. Rows compare equal unless something they display changed, so
/// finished messages are skipped (their own content changes still redraw them, via the
/// model's observation tracking).
@MainActor
final class MessageRowEquatableTests: XCTestCase {
    private let msg = Message(role: .assistant, content: "Long finished reply")

    func test_freshClosuresAloneDontCountAsAChange() {
        let a = MessageRow(message: msg, modelName: "m", onReuse: { _ in }, isLiveStreaming: false)
        let b = MessageRow(message: msg, modelName: "m", onReuse: { _ in }, isLiveStreaming: false)
        XCTAssertEqual(a, b)
    }

    func test_displayedStateChangesDoCount() {
        let base = MessageRow(message: msg, modelName: "m")
        XCTAssertNotEqual(base, MessageRow(message: msg, modelName: "m", isLiveStreaming: true))
        XCTAssertNotEqual(base, MessageRow(message: msg, modelName: "m", openArtifactID: "a"))
        XCTAssertNotEqual(base, MessageRow(message: msg, modelName: "other"))
        XCTAssertNotEqual(base, MessageRow(message: Message(role: .assistant, content: "Long finished reply"),
                                           modelName: "m"))
    }
}
