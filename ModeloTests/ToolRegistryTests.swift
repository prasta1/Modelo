import XCTest
@testable import Modelo

private struct AddTool: Tool {
    let name = "add"
    let description = "adds"
    let parameters = JSONSchema(properties: [:], required: [])
    func execute(argumentsJSON: String) async throws -> String { "added: \(argumentsJSON)" }
}

private struct BoomTool: Tool {
    let name = "boom"
    let description = "throws"
    let parameters = JSONSchema(properties: [:], required: [])
    struct Err: Error {}
    func execute(argumentsJSON: String) async throws -> String { throw Err() }
}

final class ToolRegistryTests: XCTestCase {
    func test_specs_onerPerTool() {
        let r = ToolRegistry([AddTool()])
        XCTAssertEqual(r.specs().map { $0.function.name }, ["add"])
        XCTAssertFalse(r.isEmpty)
    }

    func test_execute_dispatchesByName() async {
        let r = ToolRegistry([AddTool()])
        let out = await r.execute(name: "add", argumentsJSON: #"{"a":1}"#)
        XCTAssertEqual(out, #"added: {"a":1}"#)
    }

    func test_execute_unknownTool_returnsErrorString() async {
        let r = ToolRegistry([AddTool()])
        let out = await r.execute(name: "nope", argumentsJSON: "{}")
        XCTAssertTrue(out.lowercased().contains("unknown tool"))
    }

    func test_execute_thrownError_returnedAsString_notCrash() async {
        let r = ToolRegistry([BoomTool()])
        let out = await r.execute(name: "boom", argumentsJSON: "{}")
        XCTAssertTrue(out.lowercased().contains("error"))
    }

    func test_empty() {
        XCTAssertTrue(ToolRegistry([]).isEmpty)
    }
}
