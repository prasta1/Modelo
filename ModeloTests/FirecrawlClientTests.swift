import XCTest
@testable import Modelo

final class FirecrawlClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }
    private func client() -> FirecrawlClient {
        FirecrawlClient(apiKey: "fc-test", session: StubURLProtocol.makeSession())
    }

    func test_scrape_sendsAuthAndReturnsMarkdown() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/v1/scrape"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fc-test")
            return (.stub(200), Data(#"{"success":true,"data":{"markdown":"Hello world"}}"#.utf8))
        }
        let md = try await client().scrape(url: "https://example.com")
        XCTAssertEqual(md, "Hello world")
    }

    func test_search_formatsResults() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/v1/search"))
            return (.stub(200), Data(#"{"success":true,"data":[{"url":"https://a.com","title":"A","description":"d"}]}"#.utf8))
        }
        let out = try await client().search(query: "cats", limit: 3)
        XCTAssertTrue(out.contains("A"))
        XCTAssertTrue(out.contains("https://a.com"))
    }

    func test_scrape_throwsOnHTTPError() async {
        StubURLProtocol.handler = { _ in (.stub(402), Data()) }
        do { _ = try await client().scrape(url: "https://x.com"); XCTFail("expected throw") }
        catch { /* ClientError.serverError expected */ }
    }
}
