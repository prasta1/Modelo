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

    /// Logged 2026-10-28: small scroll-ups stayed inside the "at the bottom" zone, so
    /// following stayed on and auto-scroll pulled the reader back between gestures.
    func test_userNudgeUpNearTheBottomStillPauses() {
        XCTAssertFalse(ScrollFollow.isFollowing(was: true, oldOffsetY: 11003, newOffsetY: 10990,
                                                distanceFromBottom: 33, userScrolling: true))
    }

    /// The app's own upward shift near the end (a draft box collapsing into a card)
    /// isn't the reader leaving.
    func test_nonUserShiftNearTheBottomKeepsFollowing() {
        XCTAssertTrue(ScrollFollow.isFollowing(was: true, oldOffsetY: 11003, newOffsetY: 10990,
                                               distanceFromBottom: 20, userScrolling: false))
    }
}
