import XCTest
@testable import Modelo

final class FirecrawlToolsTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }
    private func fc() -> FirecrawlClient {
        FirecrawlClient(apiKey: "fc", session: StubURLProtocol.makeSession())
    }

    func test_scrapeTool_parsesURLArgAndReturnsContent() async throws {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"success":true,"data":{"markdown":"PAGE"}}"#.utf8)) }
        let tool = FirecrawlScrapeTool(client: fc())
        XCTAssertEqual(tool.name, "firecrawl_scrape")
        let out = try await tool.execute(argumentsJSON: #"{"url":"https://x.com"}"#)
        XCTAssertEqual(out, "PAGE")
    }

    func test_searchTool_parsesQueryArg() async throws {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"success":true,"data":[{"url":"u","title":"t","description":"d"}]}"#.utf8)) }
        let tool = FirecrawlSearchTool(client: fc())
        XCTAssertEqual(tool.name, "firecrawl_search")
        let out = try await tool.execute(argumentsJSON: #"{"query":"hi"}"#)
        XCTAssertTrue(out.contains("t"))
    }

    func test_searchTool_hasQueryRequiredInSchema() {
        XCTAssertEqual(FirecrawlSearchTool(client: fc()).parameters.required, ["query"])
    }
}
