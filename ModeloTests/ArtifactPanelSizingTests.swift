import XCTest
@testable import Modelo

final class ArtifactPanelSizingTests: XCTestCase {
    func test_clamp_capsAtFortyPercentAndFloorsAt320() {
        XCTAssertEqual(ArtifactPanelSizing.clamp(1152, detailWidth: 1400), 560)   // 40% of 1400
        XCTAssertEqual(ArtifactPanelSizing.clamp(200, detailWidth: 1400), 320)
        XCTAssertEqual(ArtifactPanelSizing.clamp(450, detailWidth: 1400), 450)
    }

    /// The bug: a saved width far above the 40% cap (1152 on a 1400pt window) made
    /// dragging do nothing until the saved value fell below the cap. A drag must move
    /// the panel from where it visibly is.
    func test_dragged_startsFromTheVisibleWidth() {
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 1152, translation: 40, detailWidth: 1400), 520)
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 450, translation: -60, detailWidth: 1400), 510)
        XCTAssertEqual(ArtifactPanelSizing.dragged(storedWidth: 450, translation: -500, detailWidth: 1400), 560)
    }
}
