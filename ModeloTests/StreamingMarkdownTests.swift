import XCTest
@testable import Modelo

/// Streaming text gets inline Markdown (bold, italics, code, links) so `**bold**` doesn't
/// sit there with raw asterisks while an artifact is being written below it.
final class StreamingMarkdownTests: XCTestCase {
    private let sample = """
    **The countdown ring** is an SVG circle driven by `stroke-dashoffset` rather than an animated CSS gradient.

    **Styling and state** are centralized.
    """

    func test_boldAndCodeAreFormattedAndMarkersRemoved() {
        let out = StreamingMarkdown.attributed(sample)
        let plain = String(out.characters)
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertTrue(plain.contains("\n\n"))   // paragraph breaks survive

        let bold = out.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(out[$0.range].characters) }
        XCTAssertEqual(bold, ["The countdown ring", "Styling and state"])
        let code = out.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map { String(out[$0.range].characters) }
        XCTAssertEqual(code, ["stroke-dashoffset"])
    }

    /// Mid-stream, a bold run may not be closed yet; it shows as typed, not dropped.
    func test_unclosedBoldStaysLiteral() {
        XCTAssertEqual(String(StreamingMarkdown.attributed("**The count").characters), "**The count")
    }
}
