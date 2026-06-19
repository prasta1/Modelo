import XCTest
@testable import Modelo

final class UsageMathTests: XCTestCase {
    func test_tokensPerSecond_dividesByElapsed() {
        XCTAssertEqual(UsageMath.tokensPerSecond(completionTokens: 120, elapsed: 2.0), 60.0, accuracy: 0.001)
    }

    func test_tokensPerSecond_zeroElapsedReturnsZero() {
        XCTAssertEqual(UsageMath.tokensPerSecond(completionTokens: 50, elapsed: 0), 0)
    }

    func test_millis_roundsSecondsToInt() {
        XCTAssertEqual(UsageMath.millis(0.412), 412)
    }
}
