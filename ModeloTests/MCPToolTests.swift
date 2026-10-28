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

    // MARK: Approval gating
    // Annotations below are verbatim from @modelcontextprotocol/server-filesystem
    // and mcp-server-fetch `tools/list`. Before this gate, every MCP tool ran
    // unasked — including writes/moves anywhere the server was rooted.

    func test_requiresApproval_localReadOnly_runsUnasked() {
        // read_file, directory_tree, list_directory…
        XCTAssertFalse(MCPToolDef.requiresApproval(["readOnlyHint": true, "openWorldHint": false]))
    }

    func test_requiresApproval_destructiveWrite_asks() {
        // write_file, edit_file, move_file
        XCTAssertTrue(MCPToolDef.requiresApproval(
            ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]))
    }

    func test_requiresApproval_readOnlyButOpenWorld_asks() {
        // fetch: "read-only", but reaching the internet is how file contents leave the Mac.
        XCTAssertTrue(MCPToolDef.requiresApproval(
            ["readOnlyHint": true, "openWorldHint": true, "destructiveHint": false]))
    }

    func test_requiresApproval_missingHints_fallBackToCautiousSpecDefaults() {
        XCTAssertTrue(MCPToolDef.requiresApproval(nil))
        XCTAssertTrue(MCPToolDef.requiresApproval([:]))
        // Read-only alone leaves openWorldHint at its default (true).
        XCTAssertTrue(MCPToolDef.requiresApproval(["readOnlyHint": true]))
    }

    func test_approvalPreview_gatesOnlyToolsThatNeedApproval() {
        let client = MCPClient(config: MCPServerConfig(name: "Filesystem"))
        func tool(needsApproval: Bool) -> MCPTool {
            MCPTool(name: "write_file", description: "", parameters: JSONSchema(properties: [:], required: []),
                    serverName: "Filesystem", needsApproval: needsApproval, client: client)
        }
        XCTAssertNil(tool(needsApproval: false).approvalPreview(argumentsJSON: "{}"))

        let preview = tool(needsApproval: true).approvalPreview(argumentsJSON: #"{"path":"/Users/x/a.txt"}"#)
        XCTAssertEqual(preview?.kind, .external)
        XCTAssertEqual(preview?.title, "Call Filesystem server")
        // Arguments are shown readably, slashes unescaped, so the user sees the real path.
        XCTAssertTrue(preview?.detail.contains(#""path" : "/Users/x/a.txt""#) == true)
        // A session grant covers this one server's tool, never a same-named built-in.
        XCTAssertEqual(preview?.allowsSessionGrant, true)
        XCTAssertEqual(preview?.grantKey, "mcp:Filesystem/write_file")
    }

    /// Shell stays excluded: one grant would authorize every later command (that's YOLO).
    /// MCP tools can be granted per tool (long research shouldn't need a click per fetch).
    func test_allowsSessionGrant_everythingButShell() {
        func grant(_ kind: ToolApprovalPreview.Kind) -> Bool {
            ToolApprovalPreview(kind: kind, title: "", detail: "").allowsSessionGrant
        }
        XCTAssertTrue(grant(.write))
        XCTAssertTrue(grant(.edit))
        XCTAssertTrue(grant(.external))
        XCTAssertFalse(grant(.shell))
    }

    /// The built-in workspace `write_file` and the Filesystem MCP server's `write_file`
    /// (rooted at ~) share a name; a grant for one must not cover the other.
    func test_grantKey_separatesSameNamedBuiltInAndMCPTools() {
        let builtIn = ToolApprovalPreview(kind: .write, title: "", detail: "")
        let mcp = ToolApprovalPreview(kind: .external, title: "", detail: "",
                                      grantKey: "mcp:Filesystem/write_file")
        XCTAssertNotEqual(ChatSession.grantKey(toolName: "write_file", preview: builtIn),
                          ChatSession.grantKey(toolName: "write_file", preview: mcp))
        XCTAssertEqual(ChatSession.grantKey(toolName: "write_file", preview: builtIn), "write_file")
    }
}
