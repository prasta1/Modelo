import XCTest
@testable import Modelo

final class SlashParserTests: XCTestCase {
    func test_recognizesCommandsAndAliases() {
        XCTAssertEqual(SlashParser.parse("/help"), .help)
        XCTAssertEqual(SlashParser.parse("/?"), .help)
        XCTAssertEqual(SlashParser.parse("/clear"), .clear)
        XCTAssertEqual(SlashParser.parse("/reset"), .clear)
        XCTAssertEqual(SlashParser.parse("/copy"), .copy)
        XCTAssertEqual(SlashParser.parse("/temp 0.4"), .temperature(0.4))
        XCTAssertEqual(SlashParser.parse("/temperature 1.2"), .temperature(1.2))
        XCTAssertEqual(SlashParser.parse("/system Be terse."), .system("Be terse."))
        XCTAssertEqual(SlashParser.parse("/model qwen"), .model("qwen"))
        XCTAssertEqual(SlashParser.parse("/m llama"), .model("llama"))
    }

    func test_caseAndWhitespaceInsensitiveCommand() {
        XCTAssertEqual(SlashParser.parse("  /TEMP 0.7 "), .temperature(0.7))
    }

    func test_systemWithNoArgClearsPrompt() {
        XCTAssertEqual(SlashParser.parse("/system"), .system(""))
    }

    func test_returnsNilForOrdinaryAndUnknown() {
        XCTAssertNil(SlashParser.parse("hello there"))
        XCTAssertNil(SlashParser.parse("/unknown stuff"))   // sent as literal text
        XCTAssertNil(SlashParser.parse("/temp notanumber"))  // bad arg → literal text
        XCTAssertNil(SlashParser.parse("/model"))            // needs a query
        XCTAssertNil(SlashParser.parse(""))
    }

    func test_suggestions_onlyForBareSlashWord() {
        XCTAssertTrue(SlashParser.suggestions(for: "hello").isEmpty)   // not a command
        XCTAssertEqual(SlashParser.suggestions(for: "/").count, SlashParser.catalog.count)
        XCTAssertEqual(SlashParser.suggestions(for: "/s").map(\.token), ["system", "skills"])
        XCTAssertEqual(SlashParser.suggestions(for: "/model").map(\.token), ["model"])
        XCTAssertTrue(SlashParser.suggestions(for: "/model qwen").isEmpty)   // typing an arg
    }
}
