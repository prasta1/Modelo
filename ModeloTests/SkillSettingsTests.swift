import XCTest
@testable import Modelo

final class SkillSettingsTests: XCTestCase {
    /// A throwaway defaults suite so tests never touch the user's real settings.
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "skills-test-\(UUID().uuidString)")!
    }

    /// A temp skills folder holding one `<name>/SKILL.md` per name.
    private func folder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        for name in names {
            let d = dir.appending(path: name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "Body of \(name)".write(to: d.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func test_load_defaults() {
        let s = SkillSettings.load(from: suite())
        XCTAssertEqual(s.folders, [SkillFolder(path: SkillSettings.defaultFolderPath, enabled: true)])
        XCTAssertTrue(s.disabled.isEmpty)
        XCTAssertTrue(s.autoEnable)
    }

    func test_saveLoad_roundTrips() {
        let d = suite()
        var s = SkillSettings.load(from: d)
        s.folders.append(SkillFolder(path: "/tmp/x", enabled: false))
        s.disabled = ["a"]
        s.known = ["a", "b"]
        s.autoEnable = false
        s.save(to: d)
        XCTAssertEqual(SkillSettings.load(from: d), s)
    }

    func test_discover_autoEnableOn_newSkillsEnabled() throws {
        var s = SkillSettings.load(from: suite())
        s.folders = [SkillFolder(path: try folder(["x"]).path, enabled: true)]
        XCTAssertEqual(s.discover().map(\.name), ["x"])
        XCTAssertEqual(s.known, ["x"])
        XCTAssertTrue(s.isEnabled("x"))
    }

    func test_discover_autoEnableOff_newSkillsDisabled() throws {
        var s = SkillSettings.load(from: suite())
        s.folders = [SkillFolder(path: try folder(["x", "y"]).path, enabled: true)]
        s.autoEnable = false
        s.known = ["x"]
        _ = s.discover()
        XCTAssertTrue(s.isEnabled("x"))
        XCTAssertFalse(s.isEnabled("y"))
    }

    func test_discover_skipsDisabledFolders() throws {
        var s = SkillSettings.load(from: suite())
        s.folders = [SkillFolder(path: try folder(["x"]).path, enabled: false)]
        XCTAssertTrue(s.discover().isEmpty)
    }

    func test_enabledSkills_filtersDisabled() throws {
        let d = suite()
        var s = SkillSettings.load(from: d)
        s.folders = [SkillFolder(path: try folder(["x", "y"]).path, enabled: true)]
        s.disabled = ["x"]
        s.save(to: d)
        XCTAssertEqual(SkillSettings.enabledSkills(defaults: d).map(\.name), ["y"])
    }
}
