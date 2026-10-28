# Slash-invoked skills + Settings ▸ Skills — design

Date: 2026-10-28 · Status: draft for review · Follow-up (deferred): [#78 per-project skills](https://github.com/prasta1/Modelo/issues/78)

## Why

Typing `/brainstorming` in Modelo does nothing useful: no autocomplete, and the text goes to
the model as a plain message. Skills currently reach the model only through the `use_skill`
tool, so whether a skill runs depends on the model choosing to call it, and only when the
chat's Tools toggle is on and the model supports tools. Every other coding agent (Claude
Code, Codex, pi) lets the user pick a skill with `/` and runs it deterministically. Modelo
should behave the same way.

Separately, Modelo loads every skill in `~/.agents/skills` (~90 today), most irrelevant to
what someone uses Modelo for. Users should choose where skills come from and which are on.

## Goals

1. **`/` runs skills.**
   - Typing `/` shows enabled skills in the slash popup, below the built-in commands, each
     with its one-line description. Typing `/bra` narrows to `brainstorming`.
   - `/skills` followed by **Tab** (or Return) opens a list of only the enabled skills to
     pick from, above the composer where the command popup appears. (Today `/skills`
     flashes a comma-separated name list that disappears after a few seconds; that is
     replaced.) Each row shows name + one-line description. Typing after `/skills`
     (e.g. `/skills bra`) filters the list; ↑↓ move, Return or click picks, Esc closes.
     The list header shows "Skills · N on" and a "Settings ▸ Skills…" link that opens
     that tab.
   - Picking a skill fills `/<name> ` and leaves the cursor for optional text. Sending
     `/<name>` or `/<name> some request` invokes the skill.
   - Invocation is deterministic: the skill's instructions go to the model with the user's
     text, every time, whether or not Tools is on or the model supports tools.
   - The user's message bubble shows the skill name (a small chip/tag) and the user's own
     text, not the skill's full instructions.
   - The skill stays in effect for the rest of the conversation, because its instructions
     remain part of the history sent on later turns. The user doesn't retype it.
2. **Settings ▸ Skills tab** (new pill after Memory, app-wide):
   - **Skill folders:** `~/.agents/skills` is present by default. "Add folder…" (an
     NSOpenPanel directory picker) adds more, such as `~/.claude/skills`. Each folder has an
     on/off switch and, except the default, a Remove action.
   - **Available skills:** every skill found in enabled folders, with name, short
     description and an on/off switch. A filter box, plus "All on" / "All off" acting on the
     filtered rows. Header shows "N of M on".
   - **"Turn on new skills automatically"** switch, on by default. With it on, a skill
     that appears in a folder later is enabled; with it off, it starts disabled.
3. **One enabled set everywhere.** Only enabled skills appear in the `/` popup, in the
   `/skills` list, and in the `use_skill` tool's catalog. If no skills are enabled, the
   `use_skill` tool isn't registered.

## Non-goals

- Per-project skill selection and project `.agents/skills/` folders (#78).
- The menu bar quick chat (`MenuBarChatView`) has no slash commands today; it doesn't get
  skills in this change.
- Editing, creating or installing skills from inside Modelo.
- Skill arguments beyond free text (no `$ARGUMENTS` templating, no per-skill parameters).
- Loading a skill's supporting files (scripts, references next to `SKILL.md`). Only the
  `SKILL.md` body is sent, as today.

## Anti-goals (would count as failure even if it "works")

- Silently dumping a skill's full instructions into the visible message bubble.
- A user who never opens Settings losing skills they have today. Defaults must reproduce
  current behavior: `~/.agents/skills` on, every skill in it on.
- Breaking existing slash commands or treating unknown `/text` differently from today
  (unknown, non-skill `/words` still send as literal text).

## Constraints

- macOS SwiftUI app, SwiftData models; match existing patterns: `SlashParser` +
  `SlashParser.Spec` catalog for the popup, `SettingsSection`/`SegmentedPills` in
  `Modelo/Settings/SettingsView.swift`, `@AppStorage` keys declared as static constants
  (as `MemoryStore.enabledKey` is).
- Adding an optional property to `Message` is safe; SwiftData migrates optional
  properties without a schema version (see `endToEndTokensPerSecond`).
- Built-in commands win over a skill with the same name (`help`, `model`, `clear`, …).
- Existing tests in `ModeloTests/SlashParserTests.swift` and `AgentsLoaderTests.swift`
  must keep passing; extend them for the new parsing and folder/enabled logic.

## Decisions (made with Patrick)

- Both entry paths: `/skills` + Tab opens the list, and typing a skill name directly
  autocompletes.
- Default source `~/.agents/skills`; users can add custom folders and pick specific skills.
- App-wide only for now; per-project is #78.

## Builder's calls (Claude's, open to change)

- **How instructions reach the model:** store the skill name on the user `Message` (new
  optional `skillName: String?`); `content` holds only what the user typed after the
  name. When building the wire request (`LMStudioClient`, where user messages become
  `WireMessage`s), expand a skill-tagged user message into the skill's current
  `SKILL.md` body followed by the user's text. The bubble renders a chip from
  `skillName`. If the skill can no longer be found when the request is built, send the
  user text alone with a one-line note that the skill wasn't found.
- **Persistence of settings:** `@AppStorage` JSON-encoded string for the folder list
  (path + enabled), a set of *disabled* skill names, a set of *known* skill names (to
  tell "new" skills apart for the auto-enable switch), and a Bool for auto-enable.
  Storing disabled names rather than enabled ones makes the default "everything on".
- **Identity and clashes:** skills are keyed by name. If two enabled folders contain the
  same name, the folder listed first wins; the Settings row shows which folder it came
  from.
- **`/skills` + Tab:** typing `/skills` shows the existing popup row; Tab, Return or
  picking the row switches the popup into the skills-only list. Today `suggestions(for:)`
  stops suggesting once the draft contains a space, so `/skills <filter>` needs to be
  special-cased to keep the list open and filter it by name.
- `AgentsLoader.loadSkills` gains a variant that takes the configured folders and the
  disabled set; `use_skill` and the slash catalog both use it so they never disagree.
- **Compaction keeps active skills.** `Conversation.wireContext()` drops messages up to
  `summaryThrough`, and `performCompaction` summarizes `content` only, so a skill
  invoked early would silently fall out of a long chat. Instead, skills invoked in the
  compacted range are carried forward: their `SKILL.md` bodies go into the system prompt
  after the summary. `TokenEstimator` / `compactIfNeeded` count the expanded skill text
  so compaction triggers at the right time.
- **Turning a skill off affects new use only.** Switching a skill (or its folder) off
  hides it from the popup, `/skills` and `use_skill`. A conversation that already
  invoked it keeps receiving it. Expanding a tagged message looks the name up across
  all configured folders, enabled or not. "Skill wasn't found" is sent only when the file
  is actually gone.
- **Too big for the model's context.** If the skill body plus history won't fit the
  current model's context window (likely with Apple Intelligence's ~4K window), the
  composer refuses the send with a flash message naming the skill and its size, and
  nothing goes to the model. Skills stay listed in the popup regardless of window size.
- **Edge cases:** a bare `/skill` with no extra text is still sent (it must not be
  dropped as empty content in `wireMessages`). Edit & resend keeps the skill chip. A
  `/skill` queued while a reply streams is parsed and tagged when it's sent, like a typed
  one.

## Left to the builder

Exact chip styling, row layout in the Settings tab, keyboard handling details for Tab in
the composer, and how often to re-scan folders (on Settings open and on composer `/` is
enough).

## Reference

Wireframe from the brainstorm (Settings ▸ Skills tab, slash popup):
`.superpowers/brainstorm/…/skills-settings.html` in the session scratchpad. Ignore its
project card; that is #78.
