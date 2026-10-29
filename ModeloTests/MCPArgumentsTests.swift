import XCTest
@testable import Modelo

/// The MCP arguments field is one line of text. Splitting it on every space broke any
/// path containing a space ("~/Library/Mobile Documents/…"); it follows shell quoting.
final class MCPArgumentsTests: XCTestCase {
    func test_split_plainWords() {
        XCTAssertEqual(MCPArguments.split("-y @modelcontextprotocol/server-filesystem /Users/x"),
                       ["-y", "@modelcontextprotocol/server-filesystem", "/Users/x"])
    }

    func test_split_quotedPathWithSpaces() {
        XCTAssertEqual(MCPArguments.split(#"-y server "/Users/x/Mobile Documents" 'a b'"#),
                       ["-y", "server", "/Users/x/Mobile Documents", "a b"])
    }

    func test_split_backslashEscapedSpace_andExtraWhitespace() {
        XCTAssertEqual(MCPArguments.split(#"  run   /Users/x/My\ Folder  "#),
                       ["run", "/Users/x/My Folder"])
    }

    func test_split_empty() {
        XCTAssertEqual(MCPArguments.split("   "), [])
    }

    /// Shown back in the field, arguments must survive a round trip.
    func test_join_quotesWhatNeedsIt_andRoundTrips() {
        let args = ["-y", "server", "/Users/x/Mobile Documents", "it's"]
        let joined = MCPArguments.join(args)
        XCTAssertEqual(joined, #"-y server "/Users/x/Mobile Documents" "it's""#)
        XCTAssertEqual(MCPArguments.split(joined), args)
    }
}
