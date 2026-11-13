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
    @FocusState private var filterFocused: Bool
    /// The last bulk change, kept so "Undo" can restore the `disabled` set it replaced.
    @State private var undo: BulkChange?

    private struct BulkChange: Equatable {
        let message: String
        let previous: Set<String>
    }

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
                            .font(Theme.metric(11))
                            .foregroundStyle(Theme.textLo)
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
                        PillToggle(isOn: $folder.enabled)
                            .accessibilityLabel("Use \(folder.path)")
                            .accessibilityValue(folder.enabled ? "On" : "Off")
                            .accessibilityAddTraits(.isButton)
                            .onChange(of: folder.enabled) { rescan() }
                    }
                    // A contained row ties the far-right switch to its path.
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .panel(Theme.fill, radius: Theme.Radius.control, stroke: Theme.line)
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
                    // `.plain` + `fieldChrome` is the Settings field look (hairline, amber on focus).
                    TextField("Filter skills…", text: $filter)
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                        .fieldChrome(focused: filterFocused)
                        .frame(maxWidth: 260)
                    Button(filter.isEmpty ? "All on" : "Turn on \(filtered.count) shown") {
                        bulk("Turned on \(filtered.count) skills") { filtered.forEach { settings.disabled.remove($0.name) } }
                    }
                    Button(filter.isEmpty ? "All off" : "Turn off \(filtered.count) shown") {
                        bulk("Turned off \(filtered.count) skills") { filtered.forEach { settings.disabled.insert($0.name) } }
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.amber)
                if let undo {
                    HStack(spacing: 8) {
                        Text(undo.message).foregroundStyle(Theme.textLo)
                        Button("Undo") {
                            settings.disabled = undo.previous
                            self.undo = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.amber)
                    }
                    .font(Theme.metric(11))
                    // Gone after 8 s; `task(id:)` restarts (and cancels the old sleep) per change.
                    .task(id: undo) {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { self.undo = nil }
                    }
                }
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
                                .font(Theme.metric(11)).foregroundStyle(Theme.textLo)
                                .lineLimit(2)
                                .help(skill.description)   // tooltip carries the full, untrimmed text
                            if showSource, let source = skill.source {
                                Text((source.path as NSString).abbreviatingWithTildeInPath)
                                    .font(Theme.metric(10)).foregroundStyle(Theme.textLo)
                            }
                        }
                    }
                    .toggleStyle(SkillCheckboxStyle())   // long lists take checkboxes, not switches (HIG)
                }
            }
        }
    }

    /// Runs a bulk toggle and remembers the prior state for the Undo row.
    private func bulk(_ message: String, _ change: () -> Void) {
        let previous = settings.disabled
        change()
        undo = BulkChange(message: message, previous: previous)
    }

    private func enabledBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(name) },
            set: { on in
                undo = nil   // a single toggle after a bulk change would make "Undo" overwrite it
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

/// A checkbox that reads its colors from the active palette (the native `.checkbox`
/// style uses the system accent, so it ignored `Theme.amber` and the nine themes).
/// A `ToggleStyle` replaces only how a `Toggle` is drawn; it is still a real toggle,
/// so VoiceOver and Space-to-toggle keep working.
private struct SkillCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? Theme.amber : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(configuration.isOn ? Theme.amber : Theme.textFaint, lineWidth: 1)
                    )
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.windowBG)
                        }
                    }
                    .frame(width: 15, height: 15)
                    .padding(.top, 1)
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
