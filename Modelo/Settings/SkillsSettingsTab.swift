import AppKit
import SwiftUI

/// Settings ▸ Skills (§3.7): which folders Modelo reads skills from, and which skills
/// are switched on. Only switched-on skills appear in the `/` popup, the `/skills`
/// list and the `use_skill` tool.
struct SkillsSettingsTab: View {
    @State private var settings = SkillSettings.load()
    /// Every skill in the enabled folders, on or off.
    @State private var skills: [AgentSkill] = []
    /// Skill count per folder path, for the folder rows.
    @State private var counts: [String: Int] = [:]
    @State private var filter = ""

    private var filtered: [AgentSkill] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? skills : skills.filter {
            $0.name.lowercased().contains(f) || $0.description.lowercased().contains(f)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                foldersSection
                skillsSection
                SettingsSection("New skills") {
                    SettingToggle(title: "Turn on new skills automatically",
                                  caption: "When off, skills that appear in a folder later start switched off.",
                                  isOn: $settings.autoEnable)
                }
            }
            .settingsColumn()
            // `.scrollIndicators(.hidden)` alone loses to "Show scroll bars: Always" or an
            // attached mouse; this AppKit probe hides them like every other tab.
            .hideScrollIndicators()
        }
        .scrollIndicators(.hidden)
        .onAppear(perform: rescan)
        .onChange(of: settings) { settings.save() }
    }

    // MARK: Folders

    private var foldersSection: some View {
        SettingsSection("Skill folders") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($settings.folders) { $folder in
                    HStack(spacing: 10) {
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textHi)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(counts[folder.path] ?? 0) skills")
                            .font(Theme.metric(10))
                            .foregroundStyle(Theme.textFaint)
                        Spacer(minLength: 8)
                        if folder.path != SkillSettings.defaultFolderPath {
                            Button("Remove") {
                                settings.folders.removeAll { $0.path == folder.path }
                                rescan()
                            }
                            .buttonStyle(.plain)
                            .font(Theme.metric(11))
                            .foregroundStyle(Theme.textDim)
                        }
                        Toggle("Use \(folder.path)", isOn: $folder.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: folder.enabled) { rescan() }
                    }
                }
                Button("Add folder…", action: addFolder)
                    .buttonStyle(.plain)
                    .font(Theme.metric(11))
                    .foregroundStyle(Theme.amber)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder that holds skills (one <name>/SKILL.md per skill)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !settings.folders.contains(where: { $0.path == url.path }) else { return }
        settings.folders.append(SkillFolder(path: url.path, enabled: true))
        rescan()
    }

    // MARK: Skills

    private var skillsSection: some View {
        let enabledCount = skills.filter { settings.isEnabled($0.name) }.count
        let showSource = settings.folders.filter(\.enabled).count > 1
        return SettingsSection("Skills · \(enabledCount) of \(skills.count) on") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("Filter skills…", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("All on") { filtered.forEach { settings.disabled.remove($0.name) } }
                    Button("All off") { filtered.forEach { settings.disabled.insert($0.name) } }
                }
                .font(Theme.metric(11))
                if skills.isEmpty {
                    Text("No skills found in the enabled folders.")
                        .font(Theme.metric(11))
                        .foregroundStyle(Theme.textFaint)
                }
                ForEach(filtered, id: \.name) { skill in
                    Toggle(isOn: enabledBinding(skill.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(Theme.mono(12)).foregroundStyle(Theme.textHi)
                            Text(UseSkillTool.brief(skill.description))
                                .font(Theme.metric(10)).foregroundStyle(Theme.textFaint)
                                .lineLimit(2)
                            if showSource, let source = skill.source {
                                Text((source.path as NSString).abbreviatingWithTildeInPath)
                                    .font(Theme.metric(9)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)   // long lists take checkboxes, not switches (HIG)
                }
            }
        }
    }

    private func enabledBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(name) },
            set: { on in
                if on { settings.disabled.remove(name) } else { settings.disabled.insert(name) }
            }
        )
    }

    /// Re-reads the enabled folders. `discover()` also records newly seen skills,
    /// which the `onChange` above persists.
    private func rescan() {
        skills = settings.discover()
        counts = Dictionary(uniqueKeysWithValues: settings.folders.map {
            ($0.path, AgentsLoader.loadSkills(folders: [URL(fileURLWithPath: $0.path)]).count)
        })
    }
}
