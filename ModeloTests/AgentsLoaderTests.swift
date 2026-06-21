import XCTest
@testable import Modelo

final class AgentsLoaderTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agents-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "skills"), withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(_ root: URL, dir: String, contents: String) throws {
        let d = root.appending(path: "skills/\(dir)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try contents.write(to: d.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }

    func test_loadsSkills_parsesFrontmatterAndBody() throws {
        let root = try tempRoot()
        try writeSkill(root, dir: "lazy", contents: """
        ---
        name: ponytail
        description: >
          Forces the laziest solution that works.
          Reach for stdlib first.
        ---
        Stop at the first rung that holds.
        """)
        let skills = AgentsLoader.loadSkills(root: root)
        let s = try XCTUnwrap(skills.first)
        XCTAssertEqual(s.name, "ponytail")
        XCTAssertEqual(s.description, "Forces the laziest solution that works. Reach for stdlib first.")
        XCTAssertEqual(s.instructions, "Stop at the first rung that holds.")
    }

    func test_fallsBackToDirNameAndSkipsBadEntries() throws {
        let root = try tempRoot()
        try writeSkill(root, dir: "no-frontmatter", contents: "Just a body, no frontmatter.")
        let skills = AgentsLoader.loadSkills(root: root)
        XCTAssertEqual(skills.map(\.name), ["no-frontmatter"])   // dir name fallback
        XCTAssertEqual(skills.first?.instructions, "Just a body, no frontmatter.")
    }

    func test_missingRootIsEmpty() {
        let skills = AgentsLoader.loadSkills(root: URL(fileURLWithPath: "/nonexistent-xyz"))
        XCTAssertTrue(skills.isEmpty)
    }

    func test_useSkillTool_returnsInstructions() async throws {
        let tool = UseSkillTool(skills: [
            AgentSkill(name: "ponytail", description: "be lazy", instructions: "Do less.")
        ])
        let out = try await tool.execute(argumentsJSON: #"{"name":"ponytail"}"#)
        XCTAssertEqual(out, "Do less.")
        let miss = try await tool.execute(argumentsJSON: #"{"name":"nope"}"#)
        XCTAssertTrue(miss.contains("No skill named"))
    }
}
