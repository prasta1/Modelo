# Changelog

All notable changes to Modelo are documented here.

## [v0.2.0] — 2026-06-26

### Added
- **Project-scoped filesystem tools** — conversations started from the Projects sidebar now register live filesystem tools (`list_directory`, `read_file`, `search_files`, `write_file`, `edit_file`) scoped to the project root, giving the model real read/write access to your code
- **Favorite models** — star any model in the picker to curate a Favorites section at the top; persisted across launches
- **Projects sidebar** — browse local project directories from the sidebar and open a project-scoped chat in one click
- **Markdown rendering** — assistant messages render as formatted Markdown with syntax-highlighted code fences (via MarkdownUI + Highlightr)
- **Tools settings** — global toggle to enable/disable tool use and a configurable max-tool-rounds limit, both in Settings
- **Menu bar icon toggle** — General settings tab lets you show or hide the menu bar icon
- **Dedicated OpenRouter endpoint** — OpenRouter now has its own server kind with fixed base URL; free models get a labeled chip in the picker

### Improved
- Inference servers moved to the top toolbar; sidebar nav labels updated for clarity
- Loaded models float to the top of the model list
- MoE model size estimates corrected; LM Studio request timeout extended
- Default window size widened and centered on launch
- Model size shown in the spec strip below the model name
- OpenRouter model metadata parsing improved (pricing, context length, free-tier detection)
- `FilterPill` labels clamped to one line to prevent wrapping on narrow pills

### Fixed
- Duplicate entries in the Favorites section of the model picker
- Return/Shift+Return key bindings (Return = newline, Shift+Return = send)
- Model loaded indicator and unload spinner

---

## [v0.1.1] — 2025-11-14

- Rename project from Strafe to Modelo
- Fix model loaded/unloaded indicator

## [v0.1.0] — 2025-11-10

- Initial release
