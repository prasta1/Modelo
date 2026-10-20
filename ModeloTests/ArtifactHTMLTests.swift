import XCTest
@testable import Modelo

final class ArtifactHTMLTests: XCTestCase {

    /// A bare HTML fragment (no `<head>`) saved by the user must be wrapped in the
    /// themed document — otherwise it opens as unstyled black text on the browser's
    /// default canvas (the "bland" export the user reported).
    func test_htmlFragmentExport_wrapsInStyledDocumentWithSolidBg() {
        let fragment = "<h1>Hello, World!</h1><p>Styled content</p>"
        let artifact = Artifact(id: "frag", title: "Greeting", kind: .html,
                                language: nil, content: fragment)

        let exported = ArtifactHTML.document(for: artifact, dark: true, forExport: true)

        // Fragment content is preserved inside the wrapped document.
        XCTAssertTrue(exported.contains("<h1>Hello, World!</h1>"),
                      "Fragment body content must survive the themed wrapper")
        // The wrapper provides structural styling (not raw text).
        XCTAssertTrue(exported.contains("<style>"),
                      "Exported fragment must be wrapped in a styled HTML document")
        XCTAssertTrue(exported.contains("</body></html>"),
                      "Exported fragment must be a complete HTML document")
        // No transparent background — the whole point of forExport.
        XCTAssertFalse(exported.contains("transparent"),
                       "Exported HTML must not rely on a transparent background")
    }

    /// The live preview in the artifact panel must keep the transparent background
    /// so the WKWebView blends with the surrounding panel chrome.
    func test_htmlFragmentPreview_keepsTransparentBackground() {
        let fragment = "<h1>Hello</h1>"
        let artifact = Artifact(id: "frag", title: "Greeting", kind: .html,
                                language: nil, content: fragment)

        let preview = ArtifactHTML.document(for: artifact, dark: true, forExport: false)

        XCTAssertTrue(preview.contains("background:transparent"),
                      "Preview must keep transparent background for WKWebView blending")
    }

    /// A complete HTML document (with `<head>`) should not be re-wrapped — its own
    /// CSS should win. For export, a zero-specificity background fallback is injected
    /// so documents that don't set their own background still get a solid canvas.
    func test_completeHTMLDocumentExport_preservesBodyAndInjectsBgFallback() {
        let doc = "<!doctype html><html><head><title>T</title></head><body><h1>Hi</h1></body></html>"
        let artifact = Artifact(id: "doc", title: "Page", kind: .html,
                                language: nil, content: doc)

        let exported = ArtifactHTML.document(for: artifact, dark: true, forExport: true)

        // Original body is untouched, not double-wrapped.
        XCTAssertTrue(exported.contains("<body><h1>Hi</h1></body>"),
                      "Complete document body must be preserved verbatim")
        // A zero-specificity background fallback was injected (not transparent).
        XCTAssertFalse(exported.contains("background:transparent"),
                       "Exported complete document must not have a transparent background")
        XCTAssertTrue(exported.contains(":where(html,body)"),
                      "Exported complete document must get a zero-specificity CSS fallback")
    }
}