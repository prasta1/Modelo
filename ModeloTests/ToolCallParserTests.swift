import XCTest
@testable import Modelo

final class ToolCallParserTests: XCTestCase {
    func test_parsesTaggedToolCall() {
        let text = "Sure.\n<tool_call>{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.txt\"}}</tool_call>"
        let (calls, cleaned) = ToolCallParser.extract(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertTrue(calls.first?.arguments.contains("a.txt") == true)
        XCTAssertEqual(cleaned, "Sure.")
    }

    func test_parsesFencedJSONCall() {
        let text = "```json\n{\"name\":\"grep\",\"arguments\":{\"pattern\":\"foo\"}}\n```"
        let (calls, _) = ToolCallParser.extract(from: text)
        XCTAssertEqual(calls.first?.name, "grep")
    }

    func test_parsesWholeMessageJSON() {
        let (calls, cleaned) = ToolCallParser.extract(from: "{\"name\":\"glob\",\"arguments\":{\"pattern\":\"*.swift\"}}")
        XCTAssertEqual(calls.first?.name, "glob")
        XCTAssertEqual(cleaned, "")
    }

    func test_unwrapsFunctionWrapper() {
        let text = "<tool_call>{\"function\":{\"name\":\"bash\",\"arguments\":{\"command\":\"ls\"}}}</tool_call>"
        XCTAssertEqual(ToolCallParser.extract(from: text).calls.first?.name, "bash")
    }

    func test_ignoresOrdinaryText() {
        let (calls, cleaned) = ToolCallParser.extract(from: "Here is a plain answer, no tools.")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(cleaned, "Here is a plain answer, no tools.")
    }

    func test_ignoresNonCallCodeBlock() {
        let (calls, _) = ToolCallParser.extract(from: "```json\n{\"foo\": 1}\n```")
        XCTAssertTrue(calls.isEmpty)
    }
}
