import XCTest
import SwiftUI
@testable import Modelo

/// The Memory tab's enable card isn't in a scroll view, so whatever height a setting
/// row asks for, the window grows to give it — a caption that measures itself at a
/// near-zero width (one word per line) pushed the window off the bottom of the screen.
@MainActor
final class SettingRowLayoutTests: XCTestCase {
    private let caption = "Models can save durable facts with save_memory and see a compact index of them in every chat. Project chats also get project-scoped memories."

    func test_settingToggle_asksForAReasonableHeight() {
        let row = SettingToggle(title: "Remember facts across conversations", caption: caption,
                                isOn: .constant(true))
        let height = NSHostingView(rootView: row).fittingSize.height
        XCTAssertLessThan(height, 120, "a two-line setting row must not ask for \(height)pt")
    }

    /// Mirrors the Memory tab: the enable card in a settings column above a greedy
    /// manager, in a non-scrolling VStack.
    func test_memoryTabShape_asksForAReasonableHeight() {
        let tab = VStack(spacing: 0) {
            SettingsSection("Memory") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingToggle(title: "Remember facts across conversations", caption: caption,
                                  isOn: .constant(true))
                    Text("Off by default — one-off conversations stay one-off. Costs a line of context per memory. Open chats pick the change up from their next message.")
                        .font(Theme.metric(10))
                }
            }
            .settingsColumn()
            Divider()
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let fitting = NSHostingView(rootView: tab).fittingSize
        XCTAssertLessThan(fitting.height, 400, "Memory tab asks for \(fitting)")
        let at900 = NSHostingView(rootView: tab.frame(width: 900)).fittingSize
        XCTAssertLessThan(at900.height, 400, "Memory tab at 900pt asks for \(at900)")
        // The main window can't be shorter than its content's *minimum* size, which is
        // measured with a zero proposal — not the fitting size above. A caption pinned
        // to its full height wraps a word per line at ~0 width and grew the window
        // off the screen (logged 2026-10-29).
        let minimum = NSHostingController(rootView: tab).sizeThatFits(in: .zero)
        XCTAssertLessThan(minimum.height, 400, "Memory tab's minimum size is \(minimum)")
    }

    func test_settingRow_asksForAReasonableHeight() {
        let row = SettingRow(title: "Max tool calls per turn", caption: caption) { Text("20") }
        let height = NSHostingView(rootView: row).fittingSize.height
        XCTAssertLessThan(height, 120, "a two-line setting row must not ask for \(height)pt")
    }
}
