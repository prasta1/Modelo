import XCTest
@testable import Modelo

/// Which light a sidebar row shows, highest priority first: the chat you're in shows
/// none; then waiting on you (approval), a failed turn, running, finished-unseen.
final class ConversationStatusTests: XCTestCase {
    private func status(active: Bool = false, streaming: Bool = false, approval: Bool = false,
                        failed: Bool = false, unseen: Bool = false) -> ConversationStatus {
        ConversationStatus.resolve(isActive: active, isStreaming: streaming, needsApproval: approval,
                                   unseenFailure: failed, unseenCompletion: unseen)
    }

    func test_selectedChatShowsNoLight() {
        XCTAssertEqual(status(active: true, streaming: true, approval: true), .none)
    }

    func test_priorityOrder() {
        XCTAssertEqual(status(streaming: true, approval: true, failed: true), .needsApproval)
        XCTAssertEqual(status(streaming: true, failed: true, unseen: true), .failed)
        XCTAssertEqual(status(streaming: true, unseen: true), .running)
        XCTAssertEqual(status(unseen: true), .finished)
        XCTAssertEqual(status(), .none)
    }

    func test_accessibilityLabels() {
        XCTAssertEqual(ConversationStatus.needsApproval.accessibilityLabel, "Needs approval")
        XCTAssertEqual(ConversationStatus.failed.accessibilityLabel, "Problem")
        XCTAssertEqual(ConversationStatus.running.accessibilityLabel, "Running")
        XCTAssertEqual(ConversationStatus.finished.accessibilityLabel, "Finished")
        XCTAssertNil(ConversationStatus.none.accessibilityLabel)
    }
}
