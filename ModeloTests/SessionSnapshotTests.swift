import XCTest
import AppKit
@testable import Modelo

final class SessionSnapshotTests: XCTestCase {

    private func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func test_caption_joinsTitleModelAndDate() {
        let s = SessionSnapshot.caption(title: "My Chat", modelID: "qwen/qwen3-32b",
                                        stamp: stamp(2026, 7, 6, 9, 5))
        XCTAssertEqual(s, "My Chat  ·  qwen/qwen3-32b  ·  2026-07-06 09:05")
    }

    func test_caption_omitsEmptyTitleAndMissingModel() {
        let s = SessionSnapshot.caption(title: "  ", modelID: nil, stamp: stamp(2026, 1, 2, 23, 59))
        XCTAssertEqual(s, "2026-01-02 23:59")
    }

    @MainActor
    func test_card_sizesToShotPlusMarginsAndCaption() throws {
        let shot = NSImage(size: NSSize(width: 200, height: 100))
        shot.lockFocus(); NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); shot.unlockFocus()

        let card = try XCTUnwrap(SessionSnapshot.card(from: shot, caption: "t", scale: 2))
        XCTAssertEqual(card.size.width, 200 + SessionSnapshot.margin * 2)
        XCTAssertEqual(card.size.height, 100 + SessionSnapshot.margin + SessionSnapshot.captionBand)
        // Pixel buffer is backing-scale sized so the PNG stays Retina-sharp.
        XCTAssertEqual(card.pixelsWide, Int(card.size.width) * 2)
        XCTAssertNotNil(card.representation(using: .png, properties: [:]))
    }

    /// At 2× the drawing must fill the whole buffer, not the bottom-left quarter.
    @MainActor
    func test_card_drawsShotAtBackingScale() throws {
        let shot = NSImage(size: NSSize(width: 200, height: 100))
        shot.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); shot.unlockFocus()

        let card = try XCTUnwrap(SessionSnapshot.card(from: shot, caption: "t", scale: 2))
        // A point near the shot's top-right corner, in top-left-origin pixel coordinates.
        let x = Int((SessionSnapshot.margin + 190) * 2)
        let y = Int((card.size.height - SessionSnapshot.captionBand - 90) * 2)
        let px = try XCTUnwrap(card.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(px.redComponent, 0.9)
    }
}
