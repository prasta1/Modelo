import Foundation

/// A folder of skills (`<name>/SKILL.md` per skill) the user has added in
/// Settings ▸ Skills (§3.7).
struct SkillFolder: Codable, Equatable, Identifiable {
    var path: String
    var enabled: Bool
    var id: String { path }
}

/// Which skill folders Modelo reads and which skills are switched on (§3.7). Stored in
/// UserDefaults; the default (`~/.agents/skills`, everything on) matches the behavior
/// before this setting existed. Disabled names are stored rather than enabled ones so
/// "everything on" is the empty default.
struct SkillSettings: Equatable {
    static let foldersKey = "skillFolders"
    static let disabledKey = "skillsDisabled"
    static let knownKey = "skillsKnown"
    static let autoEnableKey = "skillsAutoEnable"

    static var defaultFolderPath: String {
        AgentsLoader.defaultRoot.appending(path: "skills").path
    }

    var folders: [SkillFolder]
    var disabled: Set<String>
    /// Every skill name seen so far, so a skill that shows up later can be told apart
    /// as "new" for the auto-enable switch.
    var known: Set<String>
    var autoEnable: Bool

    /// Reads the settings, falling back to the defaults for anything never saved.
    static func load(from defaults: UserDefaults = .standard) -> SkillSettings {
        let folders = defaults.data(forKey: foldersKey)
            .flatMap { try? JSONDecoder().decode([SkillFolder].self, from: $0) }
            ?? [SkillFolder(path: defaultFolderPath, enabled: true)]
        return SkillSettings(
            folders: folders,
            disabled: Set(defaults.stringArray(forKey: disabledKey) ?? []),
            known: Set(defaults.stringArray(forKey: knownKey) ?? []),
            autoEnable: defaults.object(forKey: autoEnableKey) as? Bool ?? true
        )
    }

    /// Writes every field back to `defaults`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(folders), forKey: Self.foldersKey)
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        defaults.set(known.sorted(), forKey: Self.knownKey)
        defaults.set(autoEnable, forKey: Self.autoEnableKey)
    }

    /// All skills in enabled folders, switched on or not. Names not seen before are
    /// recorded in `known`, and also disabled when `autoEnable` is off.
    mutating func discover() -> [AgentSkill] {
        let urls = folders.filter(\.enabled).map { URL(fileURLWithPath: $0.path) }
        let skills = AgentsLoader.loadSkills(folders: urls)
        for skill in skills where !known.contains(skill.name) {
            known.insert(skill.name)
            if !autoEnable { disabled.insert(skill.name) }
        }
        return skills
    }

    func isEnabled(_ name: String) -> Bool { !disabled.contains(name) }

    /// The skills that are switched on, for the slash popup and the `use_skill` tool.
    /// Saves back only when discovery recorded new names.
    static func enabledSkills(defaults: UserDefaults = .standard) -> [AgentSkill] {
        var settings = load(from: defaults)
        let before = settings
        let skills = settings.discover()
        if settings != before { settings.save(to: defaults) }
        return skills.filter { settings.isEnabled($0.name) }
    }
}
