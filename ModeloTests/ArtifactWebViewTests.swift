import XCTest
@testable import Modelo

/// The preview reloaded its page on every SwiftUI update — ~115 reloads in a minute
/// while a reply streamed (logged 2026-10-28) — wiping whatever the user was doing in it.
/// It must load only when the artifact's document actually changes.
@MainActor
final class ArtifactWebViewTests: XCTestCase {
    func test_loadsOnlyWhenTheDocumentChanges() {
        let c = ArtifactWebView.Coordinator()
        XCTAssertTrue(c.shouldLoad("<p>v1</p>"))
        XCTAssertFalse(c.shouldLoad("<p>v1</p>"))   // re-render, same page: keep its state
        XCTAssertFalse(c.shouldLoad("<p>v1</p>"))
        XCTAssertTrue(c.shouldLoad("<p>v2</p>"))    // new version: load it
    }

    /// After the web engine dies, the same document must load again.
    func test_reloadsAfterTheWebProcessDies() {
        let c = ArtifactWebView.Coordinator()
        XCTAssertTrue(c.shouldLoad("<p>v1</p>"))
        c.forgetLoadedDocument()
        XCTAssertTrue(c.shouldLoad("<p>v1</p>"))
    }
}
