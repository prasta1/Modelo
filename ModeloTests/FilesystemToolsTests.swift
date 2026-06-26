import XCTest
@testable import Modelo

final class FilesystemToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "fs-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var scope: WorkspaceScope { WorkspaceScope(root: root) }

    // MARK: WorkspaceScope

    func test_scope_resolvesRelativeWithinRoot() throws {
        let url = try scope.resolve("a/b.txt")
        XCTAssertTrue(url.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    func test_scope_rejectsTraversal() {
        XCTAssertThrowsError(try scope.resolve("../escape.txt"))
        XCTAssertThrowsError(try scope.resolve("a/../../escape.txt"))
    }

    func test_scope_rejectsAbsoluteOutside() {
        XCTAssertThrowsError(try scope.resolve("/etc/passwd"))
    }

    // MARK: Write / Read round trip

    func test_writeThenRead() async throws {
        let write = WriteFileTool(scope: scope)
        _ = try await write.execute(argumentsJSON: #"{"path":"notes.md","content":"hello\nworld"}"#)
        let read = ReadFileTool(scope: scope)
        let out = try await read.execute(argumentsJSON: #"{"path":"notes.md"}"#)
        XCTAssertTrue(out.contains("hello"))
        XCTAssertTrue(out.contains("world"))
        XCTAssertTrue(out.contains("1"))   // line numbers present
    }

    func test_write_isMutating_andPreviews() {
        let write = WriteFileTool(scope: scope)
        XCTAssertTrue(write.isMutating)
        XCTAssertNotNil(write.approvalPreview(argumentsJSON: #"{"path":"x.txt","content":"hi"}"#))
    }

    // MARK: Edit

    func test_edit_replacesUniqueOccurrence() async throws {
        let path = root.appending(path: "f.txt")
        try "alpha beta gamma".write(to: path, atomically: true, encoding: .utf8)
        let edit = EditFileTool(scope: scope)
        _ = try await edit.execute(argumentsJSON: #"{"path":"f.txt","old_string":"beta","new_string":"BETA"}"#)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "alpha BETA gamma")
    }

    func test_edit_failsOnAmbiguousMatch() async {
        let path = root.appending(path: "f.txt")
        try? "x x x".write(to: path, atomically: true, encoding: .utf8)
        let edit = EditFileTool(scope: scope)
        do {
            _ = try await edit.execute(argumentsJSON: #"{"path":"f.txt","old_string":"x","new_string":"y"}"#)
            XCTFail("expected ambiguity error")
        } catch { /* expected */ }
    }

    // MARK: Glob

    func test_glob_matchesNested() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try "a".write(to: root.appending(path: "src/a.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appending(path: "readme.md"), atomically: true, encoding: .utf8)
        let glob = GlobTool(scope: scope)
        let out = try await glob.execute(argumentsJSON: #"{"pattern":"**/*.swift"}"#)
        XCTAssertTrue(out.contains("src/a.swift"))
        XCTAssertFalse(out.contains("readme.md"))
    }

    func test_globMatch_regex() {
        XCTAssertNotNil("src/a/b.swift".range(of: GlobMatch.regex(for: "**/*.swift"), options: .regularExpression))
        XCTAssertNil("notes.md".range(of: GlobMatch.regex(for: "**/*.swift"), options: .regularExpression))
    }

    // MARK: Grep

    func test_grep_findsMatches() async throws {
        try "needle here\nother line".write(to: root.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        let grep = GrepTool(scope: scope)
        let out = try await grep.execute(argumentsJSON: #"{"pattern":"needle"}"#)
        XCTAssertTrue(out.contains("log.txt"))
        XCTAssertTrue(out.contains("needle"))
    }
}
