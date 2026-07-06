import XCTest
@testable import Modelo

/// Covers the size cap on MCP tool results. External servers, unlike the
/// first-party tools, put no bound on their output — an oversized result must be
/// clipped before it lands in the conversation, or it rides every subsequent
/// request and blows the context window (issue observed with `directory_tree`
/// returning 1.8M chars ≈ 496k tokens against a 262k window).
final class MCPToolTests: XCTestCase {
    func test_clipped_shortResult_passesThroughUnchanged() {
        XCTAssertEqual(MCPTool.clipped("hello"), "hello")
    }

    func test_clipped_atLimit_passesThroughUnchanged() {
        let text = String(repeating: "a", count: MCPTool.resultCharacterLimit)
        XCTAssertEqual(MCPTool.clipped(text), text)
    }

    func test_clipped_oversizedResult_truncatesWithActionableMarker() {
        let text = String(repeating: "a", count: MCPTool.resultCharacterLimit + 500_000)
        let out = MCPTool.clipped(text)
        // Keeps the head of the result, drops the rest.
        XCTAssertTrue(out.hasPrefix(String(repeating: "a", count: 1000)))
        // Stays within the cap plus a small marker allowance.
        XCTAssertLessThan(out.count, MCPTool.resultCharacterLimit + 200)
        // Tells the model what happened so it can correct course next round.
        XCTAssertTrue(out.contains("truncated"))
    }
}
