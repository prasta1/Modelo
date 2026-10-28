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
        XCTAssertEqual(SlashParser.parse("/compact"), .compact)
        XCTAssertEqual(SlashParser.parse("/summarize"), .compact)
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

    // MARK: Skills (§3.7)

    private let skills = [
        AgentSkill(name: "brainstorming", description: "Explore intent first. More detail.", instructions: "x"),
        AgentSkill(name: "system", description: "Clashes with a built-in.", instructions: "x"),
    ]

    func test_parse_skillWithText() {
        XCTAssertEqual(SlashParser.parse("/Brainstorming plan a deck", skillNames: ["brainstorming"]),
                       .skill(name: "brainstorming", text: "plan a deck"))
    }

    func test_parse_bareSkill() {
        XCTAssertEqual(SlashParser.parse("/tdd", skillNames: ["tdd"]), .skill(name: "tdd", text: ""))
    }

    func test_parse_builtInBeatsSameNamedSkill() {
        XCTAssertEqual(SlashParser.parse("/help", skillNames: ["help"]), .help)
    }

    func test_parse_unknownStillNil() {
        XCTAssertNil(SlashParser.parse("/nope hi", skillNames: ["tdd"]))
    }

    func test_suggestions_includesSkillsAfterBuiltIns() {
        XCTAssertEqual(SlashParser.suggestions(for: "/s", skills: skills).map(\.token), ["system", "skills"])
        let bra = SlashParser.suggestions(for: "/bra", skills: skills)
        XCTAssertEqual(bra.map(\.token), ["brainstorming"])
        XCTAssertEqual(bra.first?.isSkill, true)
        XCTAssertEqual(bra.first?.summary, "Explore intent first.")
        XCTAssertTrue(bra.first?.takesArg == true)   // picking leaves room for a request
    }

    func test_suggestions_skillsListMode_filtersByText() {
        XCTAssertTrue(SlashParser.isSkillsListMode("/skills "))
        XCTAssertFalse(SlashParser.isSkillsListMode("/skills"))
        XCTAssertEqual(SlashParser.suggestions(for: "/skills ", skills: skills).map(\.token),
                       ["brainstorming"])   // `system` clashes with a built-in, so it can't run
        XCTAssertEqual(SlashParser.suggestions(for: "/Skills AIN", skills: skills).map(\.token), ["brainstorming"])
    }

    func test_skillsCatalogEntry_takesFilterSoPickingOpensList() {
        XCTAssertEqual(SlashParser.catalog.first { $0.token == "skills" }?.takesArg, true)
    }

    /// A skill named like a built-in alias (`/summarize` = `/compact`) must not be
    /// offered: picking it would run the built-in and drop the typed request.
    func test_suggestions_hideSkillsNamedLikeBuiltInAliases() {
        let clashing = ["summarize", "Help", "save", "sys"].map {
            AgentSkill(name: $0, description: "", instructions: "x")
        }
        XCTAssertTrue(SlashParser.suggestions(for: "/su", skills: clashing).allSatisfy { !$0.isSkill })
        XCTAssertTrue(SlashParser.suggestions(for: "/", skills: clashing).allSatisfy { !$0.isSkill })
        XCTAssertTrue(SlashParser.suggestions(for: "/skills ", skills: clashing).isEmpty)
    }
}
