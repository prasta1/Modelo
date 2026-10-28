import XCTest
@testable import Modelo

final class ArtifactPanelSizingTests: XCTestCase {
    /// No percentage cap: the panel can grow until the chat hits its 360pt minimum.
    func test_clamp_leavesTheChatItsMinimumAndFloorsAt320() {
        XCTAssertEqual(ArtifactPanelSizing.clamp(1152, detailWidth: 1400), 1040)   // 1400 − 360
        XCTAssertEqual(ArtifactPanelSizing.clamp(800, detailWidth: 1400), 800)     // over 40%, now allowed
        XCTAssertEqual(ArtifactPanelSizing.clamp(200, detailWidth: 1400), 320)
    }

    /// The bug: a saved width above the cap swallowed every drag until it fell back
    /// under it. A drag must move the panel from where it visibly is.
    func test_dragged_startsFromTheVisibleWidth() {
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 1300, translation: 40, detailWidth: 1400), 1000)
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 450, translation: -60, detailWidth: 1400), 510)
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 450, translation: -800, detailWidth: 1400), 1040)
    }
}
