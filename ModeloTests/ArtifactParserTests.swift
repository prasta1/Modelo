import XCTest
@testable import Modelo

final class ArtifactParserTests: XCTestCase {
    func test_extractsArtifactAndLeavesSentinel() {
        let text = "Here's a page:\n<artifact title=\"Hello\" type=\"html\" identifier=\"hello\"><h1>Hi</h1></artifact>\nEnjoy."
        let (arts, cleaned) = ArtifactParser.extract(from: text)
        XCTAssertEqual(arts.count, 1)
        XCTAssertEqual(arts[0].id, "hello")
        XCTAssertEqual(arts[0].kind, .html)
        XCTAssertEqual(arts[0].content, "<h1>Hi</h1>")
        XCTAssertTrue(cleaned.contains("\u{E000}hello\u{E000}"))
        XCTAssertTrue(cleaned.contains("Here's a page:"))
        XCTAssertTrue(cleaned.contains("Enjoy."))
        XCTAssertFalse(cleaned.contains("<artifact"))
    }

    func test_codeArtifactCarriesLanguage() {
        let text = "<artifact title=\"Fib\" type=\"code\" language=\"python\">def f(): pass</artifact>"
        let arts = ArtifactParser.extract(from: text).artifacts
        XCTAssertEqual(arts.first?.kind, .code)
        XCTAssertEqual(arts.first?.language, "python")
    }

    func test_idFallsBackToSluggedTitle() {
        let arts = ArtifactParser.extract(from: "<artifact title=\"My Cool Thing\" type=\"svg\"><svg/></artifact>").artifacts
        XCTAssertEqual(arts.first?.id, "my-cool-thing")
    }

    func test_noArtifactsReturnsOriginal() {
        let text = "Just a normal reply with a `code` span and\n```swift\nlet x = 1\n```"
        let (arts, cleaned) = ArtifactParser.extract(from: text)
        XCTAssertTrue(arts.isEmpty)
        XCTAssertEqual(cleaned, text)
    }

    func test_collectorGroupsVersionsByID() {
        let m1 = Message(role: .assistant, content: "<artifact title=\"App\" type=\"html\" identifier=\"app\">v1</artifact>")
        let m2 = Message(role: .assistant, content: "<artifact title=\"App\" type=\"html\" identifier=\"app\">v2</artifact>")
        let groups = ArtifactCollector.groups(from: [m1, m2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].versions.count, 2)
        XCTAssertEqual(groups[0].latest.content, "v2")
    }

    // MARK: Streaming (draft box)

    func test_streaming_unclosedArtifactBecomesDraft() {
        let text = "Here you go:\n<artifact identifier=\"c\" type=\"html\" title=\"Counter\">\n<html>\n<body>"
        XCTAssertEqual(ArtifactParser.streamingSegments(from: text), [
            .text("Here you go:\n"),
            .draft(title: "Counter", kind: .html, body: "<html>\n<body>"),
        ])
    }

    /// The opening tag itself is still arriving: no title yet, no raw markup shown.
    func test_streaming_partialOpeningTagIsAnUntitledDraft() {
        XCTAssertEqual(ArtifactParser.streamingSegments(from: "Here:\n<artifact identifier=\"c\" ty"),
                       [.text("Here:\n"), .draft(title: nil, kind: .code, body: "")])
    }

    func test_streaming_closedArtifactThenNewDraft() {
        let text = "<artifact identifier=\"a\" title=\"A\">one</artifact>\nNext:\n<artifact identifier=\"b\" title=\"B\">tw"
        let segs = ArtifactParser.streamingSegments(from: text)
        XCTAssertEqual(segs.count, 3)
        guard case .artifact(let a) = segs[0] else { return XCTFail("expected a card first") }
        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(segs[1], .text("\nNext:"))   // `segments` trims the trailing newline
        XCTAssertEqual(segs[2], .draft(title: "B", kind: .code, body: "tw"))
    }

    func test_streaming_plainTextIsUnchanged() {
        XCTAssertEqual(ArtifactParser.streamingSegments(from: "just words"), [.text("just words")])
    }
}
