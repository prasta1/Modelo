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
}
