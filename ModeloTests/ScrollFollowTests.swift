import XCTest
@testable import Modelo

/// Whether the chat keeps following new output. Measured from the real scroll
/// position, so the slightest scroll up stops following (the bug: following only
/// stopped once a lazily-loaded bottom marker unloaded, far up the transcript).
final class ScrollFollowTests: XCTestCase {
    func test_scrollingUpStopsFollowingImmediately() {
        XCTAssertFalse(ScrollFollow.isFollowing(was: true, oldOffsetY: 1000, newOffsetY: 995,
                                                distanceFromBottom: 60))
    }

    /// Streamed text grows the content below the viewport; that isn't the user leaving.
    func test_contentGrowingBelowKeepsFollowing() {
        XCTAssertTrue(ScrollFollow.isFollowing(was: true, oldOffsetY: 1000, newOffsetY: 1000,
                                               distanceFromBottom: 220))
    }

    func test_returningToTheBottomResumesFollowing() {
        XCTAssertTrue(ScrollFollow.isFollowing(was: false, oldOffsetY: 900, newOffsetY: 1180,
                                               distanceFromBottom: 10))
    }

    func test_scrollingDownButNotToTheBottomStaysPaused() {
        XCTAssertFalse(ScrollFollow.isFollowing(was: false, oldOffsetY: 500, newOffsetY: 700,
                                                distanceFromBottom: 400))
    }
}
