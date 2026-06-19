import XCTest
@testable import Modelo

private struct SampleTool: Tool {
    let name = "sample"
    let description = "A sample"
    let parameters = JSONSchema(
        properties: ["q": .init("string", "the query")],
        required: ["q"])
    func execute(argumentsJSON: String) async throws -> String { "ok" }
}

final class ToolTypeTests: XCTestCase {
    func test_toolSpec_encodesOpenAIShape() throws {
        let spec = ToolSpec(SampleTool())
        let data = try JSONEncoder().encode(spec)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "function")
        let fn = try XCTUnwrap(obj["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "sample")
        XCTAssertEqual(fn["description"] as? String, "A sample")
        let params = try XCTUnwrap(fn["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertEqual(params["required"] as? [String], ["q"])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertNotNil(props["q"])
    }
}
