# Slash-Invoked Skills + Settings ▸ Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typing `/<skill>` (or `/skills` + Tab) runs an `~/.agents`-style skill deterministically, and a Settings ▸ Skills tab chooses which folders and skills are enabled.

**Architecture:** `SkillSettings` (UserDefaults-backed) + `AgentsLoader.loadSkills(folders:)` produce one enabled-skill list used by the slash popup, the `/skills` list and `use_skill`. Invoking a skill snapshots its name + instructions onto the user `Message`; `Message.wireContent` expands them for the request, the token estimator, and the compaction carry-forward in `Conversation.wireContext()`.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), SwiftData, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-28-slash-skills-design.md`

## Global Constraints

- Work on branch `feature/slash-skills` in a worktree at `.worktrees/slash-skills` (never `git switch` the main checkout). Run `xcodegen generate` in the worktree before building.
- Build: `xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Test: same with `test`, single suite via `-only-testing:ModeloTests/<Suite>`.
- Tests never touch `UserDefaults.standard` or `~/.agents`: use `UserDefaults(suiteName: "skills-test-\(UUID())")!` and temp directories.
- Defaults must reproduce today: `~/.agents/skills` on, every skill in it on, auto-enable on.
- Built-in slash commands win over a same-named skill. Unknown non-skill `/words` still send as literal text.
- New `Message` properties are optional (SwiftData lightweight migration, like `endToEndTokensPerSecond`).
- Match file style: `///` doc comments on new types/functions, `§3.7` references for skills.

## Review Focus

1. Bare `/brainstorming` with no text → still sends (not dropped by `ChatSession.send`'s empty guard or `wireKeep`) → Task 2 test `test_send_bareSkill_isSentAndKept`.
2. Skill invoked early, then auto-compaction → instructions still reach the model → Task 2 test `test_wireContext_carriesSkillsFromSummarizedPrefix`.
3. Skill named like a built-in (`help`, `model`) → built-in runs → Task 3 test `test_parse_builtInBeatsSameNamedSkill`.
4. `/skills` typed then Return with the popup open → opens the list, doesn't flash names → Task 3 test `test_suggestions_skillsListMode_filtersByText` + Task 4 manual check.
5. A skill appearing in two enabled folders → first folder wins, shown once → Task 1 test `test_loadSkills_firstFolderWinsOnNameClash`.

---

### Task 1: Skill folders + enabled-skill settings

**Files:**
- Modify: `Modelo/Services/AgentsLoader.swift`
- Create: `Modelo/Services/SkillSettings.swift`
- Test: `ModeloTests/AgentsLoaderTests.swift`, Create `ModeloTests/SkillSettingsTests.swift`

**Interfaces:**
- Produces:
  - `AgentSkill` gains `var source: URL? = nil` (the skills folder it came from; existing memberwise calls keep compiling).
  - `AgentsLoader.loadSkills(folders: [URL]) -> [AgentSkill]`: each URL is a skills dir containing `<name>/SKILL.md`. First folder wins on duplicate names. Sorted by name. Existing `loadSkills(root:)` becomes `loadSkills(folders: [root.appending(path: "skills")])`.
  - `struct SkillFolder: Codable, Equatable, Identifiable { var path: String; var enabled: Bool; var id: String { path } }`
  - `struct SkillSettings: Equatable` with `var folders: [SkillFolder]`, `var disabled: Set<String>`, `var known: Set<String>`, `var autoEnable: Bool`; keys `static let foldersKey = "skillFolders"`, `disabledKey = "skillsDisabled"`, `knownKey = "skillsKnown"`, `autoEnableKey = "skillsAutoEnable"`; `static var defaultFolderPath: String` (`~/.agents/skills`, expanded).
  - `static func load(from defaults: UserDefaults = .standard) -> SkillSettings`, `func save(to defaults: UserDefaults = .standard)`.
  - `mutating func discover() -> [AgentSkill]`: all skills in *enabled* folders; any name not in `known` is added to `known`, and also to `disabled` when `!autoEnable`.
  - `func isEnabled(_ name: String) -> Bool` (`!disabled.contains(name)`).
  - `static func enabledSkills(defaults: UserDefaults = .standard) -> [AgentSkill]`: load → discover → save if changed → filter `isEnabled`.

- [ ] **Step 1: Write failing tests**

`AgentsLoaderTests`:
- `test_loadSkills_foldersMergesAndSorts`: two temp folders with `b` and `a` → names `["a", "b"]`, each `source` equals its folder.
- `test_loadSkills_firstFolderWinsOnNameClash`: `dup` in both folders with different bodies → one result, instructions from the first folder.

`SkillSettingsTests` (all with a throwaway `UserDefaults` suite):
- `test_load_defaults`: empty suite → `folders == [SkillFolder(path: SkillSettings.defaultFolderPath, enabled: true)]`, `disabled` empty, `autoEnable == true`.
- `test_saveLoad_roundTrips`: mutate every field, save, load → equal.
- `test_discover_autoEnableOn_newSkillsEnabled`: folder with `x` → `discover()` returns `x`, `known == ["x"]`, `isEnabled("x")`.
- `test_discover_autoEnableOff_newSkillsDisabled`: `autoEnable = false`, `known = ["x"]`, folder has `x`, `y` → `isEnabled("x")`, `!isEnabled("y")`.
- `test_discover_skipsDisabledFolders`: folder `enabled: false` → `discover()` is empty.
- `test_enabledSkills_filtersDisabled`: settings with `disabled = ["x"]` saved to suite, folder has `x`, `y` → `enabledSkills(defaults:)` names `["y"]`.

- [ ] **Step 2: Run, expect compile failure** — `-only-testing:ModeloTests/AgentsLoaderTests -only-testing:ModeloTests/SkillSettingsTests`.
- [ ] **Step 3: Implement** `loadSkills(folders:)` and `SkillSettings` per Interfaces. Folders are stored JSON-encoded under `foldersKey`; sets as string arrays; `autoEnable` read with `defaults.object(forKey:) as? Bool ?? true`.
- [ ] **Step 4: Run, expect PASS** (both suites, plus existing `AgentsLoaderTests`).
- [ ] **Step 5: Commit** `git add Modelo/Services/AgentsLoader.swift Modelo/Services/SkillSettings.swift ModeloTests/AgentsLoaderTests.swift ModeloTests/SkillSettingsTests.swift` — `feat(skills): configurable skill folders and enabled set`. (Run `xcodegen generate` first so the new files are in the project.)

---

### Task 2: Skill snapshot on messages, request expansion, compaction carry-forward

**Files:**
- Modify: `Modelo/Models/Message.swift`, `Modelo/Services/LMStudioClient.swift:368-400` (`wireMessages` user case), `Modelo/Services/TokenEstimator.swift`, `Modelo/Models/Conversation.swift:123` (`wireContext`), `Modelo/Services/ChatSession.swift:134-160` (`send`), `:648` (`wireKeep`)
- Test: `ModeloTests/WireMessagesTests.swift`, `TokenEstimatorTests.swift`, `CompactionTests.swift`, `ChatSessionTests.swift`

**Interfaces:**
- Consumes: `AgentSkill` (Task 1).
- Produces:
  - `Message.skillName: String?`, `Message.skillInstructions: String?`.
  - `Message.wireContent: String` (computed): `content` when no skill; otherwise exactly
    ```
    Use the "<skillName>" skill. Its instructions:

    <skillInstructions>
    ```
    followed by `"\n\n---\n\n" + content` only when `content` is non-empty.
  - `ChatSession.send(..., skill: AgentSkill? = nil, replacing:)`: new parameter placed before `replacing`; sets both message fields; empty-text guard passes when `skill != nil`.

- [ ] **Step 1: Write failing tests**
- `WireMessagesTests.test_skillTaggedUser_expandsInstructionsThenText`: message `content "plan a deck"`, `skillName "brainstorming"`, `skillInstructions "Ask one question."` → wire user text equals the `wireContent` format above.
- `WireMessagesTests.test_bareSkill_sendsInstructionsOnly`: `content ""` + skill → one user wire message, text ends with `Ask one question.` (no `---`).
- `TokenEstimatorTests.test_estimate_messagesCountsSkillInstructions`: estimate of a skill-tagged message equals `estimate(m.wireContent)`.
- `CompactionTests.test_wireContext_carriesSkillsFromSummarizedPrefix`: m1 user skill-tagged (`brainstorming`, `"Ask one question."`), m2 assistant, m3 user; `summaryThrough = m2` → `wire.system` contains `"Ask one question."` and `wire.messages.map(\.content) == ["recent"]`-style (only m3).
- `CompactionTests.test_wireContext_sameSkillTwice_carriedOnce`: two tagged messages with the same name in the prefix → instructions appear once (the later snapshot).
- `ChatSessionTests.test_send_bareSkill_isSentAndKept`: follow that file's existing stub-server pattern; `send("", ..., skill: AgentSkill(name: "s", description: "", instructions: "Do X."))` → a user message exists with `skillName == "s"`, and the captured request body contains `Do X.`.

- [ ] **Step 2: Run, expect failures** — the four suites above.
- [ ] **Step 3: Implement**
  - `wireMessages` user case and the merge logic use `m.wireContent` wherever they read `m.content` for user turns.
  - `TokenEstimator.estimate(_ messages:)` sums `estimate($0.wireContent)`.
  - `wireKeep`: also keep a message with `skillInstructions != nil`.
  - `wireContext()`: from the summarized prefix (`path[...idx]`), collect skill-tagged messages, de-duplicate by `skillName` keeping the last, and append after the summary note:
    `Skills invoked earlier in this conversation (still in effect):` followed by each block as `### <name>\n<instructions>`.
- [ ] **Step 4: Run, expect PASS**, then the full test suite.
- [ ] **Step 5: Commit** — `feat(skills): snapshot invoked skills onto messages and carry them through compaction`.

---

### Task 3: SlashParser — skill commands, skill suggestions, `/skills` list mode

**Files:**
- Modify: `Modelo/Services/SlashParser.swift`
- Test: `ModeloTests/SlashParserTests.swift`

**Interfaces:**
- Consumes: `AgentSkill` (Task 1), `UseSkillTool.brief(_:)` for one-line summaries.
- Produces:
  - `SlashCommand.skill(name: String, text: String)`; `name` is the skill's canonical (on-disk) name.
  - `SlashParser.parse(_ input: String, skillNames: [String] = []) -> SlashCommand?`: built-in switch unchanged; the `default:` branch matches `cmd` case-insensitively against `skillNames`.
  - `SlashParser.Spec` gains `var isSkill: Bool = false`.
  - Catalog `skills` entry becomes `Spec(token: "skills", arg: "[filter]", summary: "Pick from your skills")`.
  - `SlashParser.suggestions(for input: String, skills: [AgentSkill] = []) -> [Spec]`:
    - **List mode:** input (case-insensitive) starts with `/skills ` → only skill specs whose name contains the text after the space (empty text = all).
    - **Normal mode:** today's built-in matches, followed by skills whose name has the typed prefix, excluding names equal to a catalog token.
    - Skill specs: `token = name`, `arg = "[request]"`, `summary = UseSkillTool.brief(description)`, `isSkill = true`.
  - `static func isSkillsListMode(_ input: String) -> Bool`.

- [ ] **Step 1: Write failing tests**
- `test_parse_skillWithText`: `parse("/Brainstorming plan a deck", skillNames: ["brainstorming"]) == .skill(name: "brainstorming", text: "plan a deck")`.
- `test_parse_bareSkill`: `parse("/tdd", skillNames: ["tdd"]) == .skill(name: "tdd", text: "")`.
- `test_parse_builtInBeatsSameNamedSkill`: `parse("/help", skillNames: ["help"]) == .help`.
- `test_parse_unknownStillNil`: `parse("/nope hi", skillNames: ["tdd"]) == nil`.
- `test_suggestions_includesSkillsAfterBuiltIns`: skills `brainstorming`, `system` → `suggestions(for: "/s", skills:)` tokens `["system", "skills"]` (built-ins only; the `system` skill is excluded as a clash); `suggestions(for: "/bra", skills:)` → `["brainstorming"]` with `isSkill`.
- `test_suggestions_skillsListMode_filtersByText`: `suggestions(for: "/skills ", skills:)` returns every skill and no built-ins; `"/skills ain"` → `["brainstorming"]`.
- Update the existing `test_suggestions_onlyForBareSlashWord` only where the catalog change requires it.

- [ ] **Step 2: Run, expect failures** — `-only-testing:ModeloTests/SlashParserTests`.
- [ ] **Step 3: Implement** per Interfaces; update `helpText` so `/skills` reads `/skills [filter]`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `feat(skills): parse /<skill> and suggest skills in the slash popup`.

---

### Task 4: Composer wiring — invoke, list, Tab, chip, `use_skill`

**Files:**
- Modify: `Modelo/Views/ComposerField.swift` (add `var onTab: (() -> Bool)? = nil`; handle `#selector(NSResponder.insertTab(_:))` like `moveUp`), `Modelo/Views/ChatView.swift`, `Modelo/Views/MessageRow.swift` (user bubble)

**Interfaces:**
- Consumes: `SkillSettings.enabledSkills()` (Task 1), `ChatSession.send(..., skill:)` (Task 2), `SlashParser` additions (Task 3), `SettingsNavigator.open(tab:)` (existing, `ContentView.swift:65`).

- [ ] **Step 1: ChatView state.** `@State private var enabledSkills: [AgentSkill] = []`, refreshed on appear and whenever `draft` changes to start with `/` from not starting with it. Pass `skills: enabledSkills` to `SlashParser.suggestions` and `skillNames:` to `parse`.
- [ ] **Step 2: Tab.** `onTab`: if the popup is open, `applySuggestion(highlighted)` and return `true`; otherwise `false`.
- [ ] **Step 3: List popup.** When `SlashParser.isSkillsListMode(draft)`, show a header row above the rows: `"Skills · \(enabledSkills.count) on"` left, and a `Settings ▸ Skills…` plain button right that calls `settingsNavigator.open(tab: "Skills")` (add `@Environment(SettingsNavigator.self)`). Wrap rows in a `ScrollView` capped at about 8 rows tall. With zero enabled skills, show one row: `No skills are on. Settings ▸ Skills…`.
- [ ] **Step 4: `/skills` via Return.** In `send()`, after `handleSlash(command)`, set `draft = "/skills "` for `.skills` (opening the list) instead of `""`. Remove the old `.skills` flash in `handleSlash`.
- [ ] **Step 5: Invoke.** In `send()`, when `parse` returns `.skill(name, text)`: look up the `AgentSkill` in `enabledSkills`. If `contextWindow > 0` and `TokenEstimator.estimate(skill.instructions) + TokenEstimator.estimate(text) > contextWindow`, call `flash("\"\(name)\" is ~\(n) tokens — too big for this model's \(contextWindow.formatted())-token context.")` and return, keeping the draft. Otherwise continue the normal send path with `text` and pass `skill:` to `session.send`. While streaming, the raw draft is queued as today; `drainQueue` re-enters `send()`, so it gets parsed then.
- [ ] **Step 6: `use_skill` uses the enabled set.** At `ChatView.swift:1507`, replace `AgentsLoader.loadSkills()` with `SkillSettings.enabledSkills()`.
- [ ] **Step 7: Edit & resend.** `reuseDraft`: if `message.skillName` is set, draft = `"/\(name)"` + (content empty ? `" "` : `" \(content)"`).
- [ ] **Step 8: Chip.** In `MessageRow`'s user bubble, when `message.skillName` is set, show a small capsule (SF Symbol `sparkles` + name, `Theme.metric(10)`, `Theme.amber`) above the text; with empty `content`, show only the chip.
- [ ] **Step 9: Build** (Global Constraints command) → `** BUILD SUCCEEDED **`; run the full test suite → all pass.
- [ ] **Step 10: Manual check** (hand Patrick the worktree build): `/bra` → popup shows `brainstorming` under the commands; Tab fills `/brainstorming `; sending `/brainstorming plan a deck` shows a chip and the model starts asking questions with Tools **off**; `/skills` + Tab and `/skills` + Return both open the list; `/skills ain` filters; the header link opens Settings; `/help` still shows help; `/nope hi` sends literally.
- [ ] **Step 11: Commit** — `feat(skills): run skills from the composer with /<name> and /skills`.

---

### Task 5: Settings ▸ Skills tab

**Files:**
- Create: `Modelo/Settings/SkillsSettingsTab.swift`
- Modify: `Modelo/Settings/SettingsView.swift:23-55` (add `"Skills"` after `"Memory"` in `tabTitles` and a `case "Skills": SkillsSettingsTab()`)

**Interfaces:**
- Consumes: `SkillSettings`, `SkillFolder`, `AgentSkill.source` (Task 1).

- [ ] **Step 1: Build the view** following `PresetsSettingsTab` / `SettingsSection` styling. `@State private var settings = SkillSettings.load()`, `@State private var skills: [AgentSkill] = []`, `@State private var filter = ""`. Rescan with `skills = settings.discover()` on appear and after any folder change; `settings.save()` on every change.
  - **Skill folders** section: one row per folder: path (abbreviated with `~`), skill count, `Toggle` bound to `enabled`, and `Remove` for every folder except `SkillSettings.defaultFolderPath`. `Add folder…` opens `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`) and appends `SkillFolder(path:, enabled: true)`, skipping duplicates.
  - **Skills** section: header `"\(enabledCount) of \(skills.count) on"`; filter `TextField`; `All on` / `All off` buttons acting on the filtered rows; one row per filtered skill with name, `UseSkillTool.brief(description)`, source folder (dimmed, only when more than one folder is enabled), and a `Toggle` that inserts or removes the name in `settings.disabled`.
  - `Toggle("Turn on new skills automatically", isOn: $settings.autoEnable)`.
- [ ] **Step 2: Build** → `** BUILD SUCCEEDED **`; full test suite passes.
- [ ] **Step 3: Manual check:** the defaults show `~/.agents/skills` with every skill on. Turning `tdd` off removes it from the `/` popup and `/skills` in a new chat. Adding `~/.claude/skills` lists its skills, and a clashing name shows once with its source. Turning that folder off hides its skills. With auto-enable off, a newly created test skill folder appears switched off.
- [ ] **Step 4: Commit** — `feat(skills): Settings ▸ Skills tab for folders and enabled skills`.
- [ ] **Step 5: Docs.** In `README.md`, update the skills bullet (`/` invocation, Settings ▸ Skills). Commit `docs: describe slash skills and Settings ▸ Skills`.
