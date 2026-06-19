import XCTest
@testable import Modelo

final class SSELineParserTests: XCTestCase {
    func test_ignoresNonDataLines() throws {
        XCTAssertEqual(try SSELineParser.parse(": keep-alive"), .ignore)
        XCTAssertEqual(try SSELineParser.parse(""), .ignore)
    }

    func test_parsesDoneSentinel() throws {
        XCTAssertEqual(try SSELineParser.parse("data: [DONE]"), .done)
    }

    func test_parsesContentDelta() throws {
        let line = #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#
        XCTAssertEqual(try SSELineParser.parse(line), .event(.delta("Hi")))
    }

    func test_parsesUsageFrame() throws {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34}}"#
        XCTAssertEqual(try SSELineParser.parse(line), .event(.usage(promptTokens: 12, completionTokens: 34)))
    }

    func test_throwsOnErrorFrame() {
        let line = #"data: {"error":{"message":"vision not supported"}}"#
        XCTAssertThrowsError(try SSELineParser.parse(line)) { error in
            XCTAssertEqual(error as? ClientError, .serverError("vision not supported"))
        }
    }

    func test_emptyDeltaIsIgnored() throws {
        let line = #"data: {"choices":[{"delta":{}}]}"#
        XCTAssertEqual(try SSELineParser.parse(line), .ignore)
    }

    func test_garbagePayloadIsIgnored() throws {
        // A misbehaving server sending non-JSON after `data:` must degrade
        // gracefully to .ignore, not crash or throw.
        XCTAssertEqual(try SSELineParser.parse("data: not-json"), .ignore)
    }

    func test_parsesToolCallFragment() throws {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search","arguments":"{\"q\""}}]}}]}"#
        let outcome = try SSELineParser.parse(line)
        XCTAssertEqual(outcome, .toolCallDelta([
            SSELineParser.ToolCallFragment(index: 0, id: "c1", name: "search", arguments: "{\"q\"")
        ]))
    }

    func test_parsesFinishReason() throws {
        let line = #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        XCTAssertEqual(try SSELineParser.parse(line), .finish("tool_calls"))
    }
}
