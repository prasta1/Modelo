import XCTest
@testable import Modelo

final class TokenEstimatorTests: XCTestCase {
    func test_estimate_emptyIsZero() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func test_estimate_roundsUpAtFourCharsPerToken() {
        XCTAssertEqual(TokenEstimator.estimate("a"), 1)      // ceil(1/4)
        XCTAssertEqual(TokenEstimator.estimate("abcd"), 1)   // 4/4
        XCTAssertEqual(TokenEstimator.estimate("abcde"), 2)  // ceil(5/4)
        XCTAssertEqual(TokenEstimator.estimate(String(repeating: "x", count: 40)), 10)
    }

    func test_estimate_messagesSumsBodies() {
        let a = Message(role: .user, content: "abcd")        // 1
        let b = Message(role: .assistant, content: "abcdefgh") // 2
        XCTAssertEqual(TokenEstimator.estimate([a, b]), 3)
    }

    func test_estimate_messagesCountsSkillInstructions() {
        let m = Message(role: .user, content: "hi")
        m.skillName = "s"
        m.skillInstructions = String(repeating: "x", count: 400)
        XCTAssertEqual(TokenEstimator.estimate([m]), TokenEstimator.estimate(m.wireContent))
        XCTAssertGreaterThan(TokenEstimator.estimate([m]), 100)
    }

    /// A skill must leave room for the reply: 3,500 tokens doesn't fit a 4K window
    /// (Apple Intelligence) once the 1,024-token response reserve is set aside.
    func test_fits_leavesRoomForTheReply() {
        let text = String(repeating: "x", count: 3_500 * 4)
        XCTAssertFalse(TokenEstimator.fits(text, contextWindow: 4_096))
        XCTAssertTrue(TokenEstimator.fits(text, contextWindow: 32_768))
        XCTAssertTrue(TokenEstimator.fits(text, contextWindow: 0))   // unknown window → allow
    }
}
