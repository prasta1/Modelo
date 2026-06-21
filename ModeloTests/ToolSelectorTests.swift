import XCTest
@testable import Modelo

final class ToolSelectorTests: XCTestCase {
    private let catalog: [(name: String, description: String)] = [
        ("read_file",  "Read a text file inside the workspace."),
        ("write_file", "Create or overwrite a file."),
        ("edit_file",  "Replace an exact string in a file."),
        ("grep",       "Search file contents for a regular expression."),
        ("glob",       "List files matching a glob pattern."),
        ("bash",       "Run a shell command."),
        ("firecrawl_search", "Search the web."),
    ]

    func test_rankByRelevance() {
        let picks = ToolSelector.select(catalog: catalog, query: "read a file", limit: 3)
        XCTAssertEqual(picks.first, "read_file")          // name hit ranks top
        XCTAssertTrue(picks.contains("read_file"))
        XCTAssertEqual(picks.count, 3)
    }

    func test_webQueryPrefersWebTool() {
        let picks = ToolSelector.select(catalog: catalog, query: "search the web for news", limit: 2)
        XCTAssertTrue(picks.contains("firecrawl_search"))
    }

    func test_emptyQueryFallsBackAlphabetical() {
        let picks = ToolSelector.select(catalog: catalog, query: "", limit: 3)
        XCTAssertEqual(picks, ["bash", "edit_file", "firecrawl_search"])
    }

    func test_respectsLimit() {
        XCTAssertEqual(ToolSelector.select(catalog: catalog, query: "file", limit: 2).count, 2)
    }
}
