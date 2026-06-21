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
}
