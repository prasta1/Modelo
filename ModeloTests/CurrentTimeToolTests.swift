import XCTest
@testable import Modelo

final class CurrentTimeToolTests: XCTestCase {
    private let tool = CurrentTimeTool()

    // MARK: Timezone resolution

    func test_execute_validTimezone_outputContainsAbbreviation() async throws {
        let result = try await tool.execute(argumentsJSON: #"{"timezone":"UTC"}"#)
        // DateFormatter renders the UTC zone as "GMT" (both name the same zero-offset zone).
        let hasUTC = result.contains("UTC") || result.contains("GMT")
        XCTAssertTrue(hasUTC, "Expected UTC or GMT in output, got: \(result)")
    }

    func test_execute_namedTimezone_outputContainsAbbreviation() async throws {
        // America/New_York produces EST or EDT depending on the time of year.
        let result = try await tool.execute(argumentsJSON: #"{"timezone":"America/New_York"}"#)
        let hasEastern = result.contains("EST") || result.contains("EDT") || result.contains("ET")
        XCTAssertTrue(hasEastern, "Expected Eastern timezone abbreviation, got: \(result)")
    }

    func test_execute_invalidTimezone_doesNotThrow() async throws {
        // Falls back to local timezone — must not crash or throw.
        let result = try await tool.execute(argumentsJSON: #"{"timezone":"Not/ARealZone"}"#)
        XCTAssertFalse(result.isEmpty)
    }

    func test_execute_emptyTimezoneString_doesNotThrow() async throws {
        let result = try await tool.execute(argumentsJSON: #"{"timezone":""}"#)
        XCTAssertFalse(result.isEmpty)
    }

    func test_execute_missingField_doesNotThrow() async throws {
        let result = try await tool.execute(argumentsJSON: "{}")
        XCTAssertFalse(result.isEmpty)
    }

    func test_execute_malformedJSON_doesNotThrow() async throws {
        // JSONDecoder failure → falls back to local timezone.
        let result = try await tool.execute(argumentsJSON: "not json")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: Output format

    func test_execute_outputContainsAtLiteral() async throws {
        // Format: "EEEE, MMMM d, yyyy 'at' h:mm:ss a zzz"
        let result = try await tool.execute(argumentsJSON: #"{"timezone":"UTC"}"#)
        XCTAssertTrue(result.contains(" at "), "Expected ' at ' in output, got: \(result)")
    }

    // MARK: Tool metadata

    func test_name_isGetCurrentTime() {
        XCTAssertEqual(tool.name, "get_current_time")
    }

    func test_alwaysVisible_isTrue() {
        XCTAssertTrue(tool.alwaysVisible)
    }

    func test_parameters_timezoneIsNotRequired() {
        XCTAssertFalse(tool.parameters.required.contains("timezone"))
    }
}
