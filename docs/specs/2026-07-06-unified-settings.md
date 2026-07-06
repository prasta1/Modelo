# Design: Single in-app Settings

**Date:** 2026-07-06
**Status:** Proposed (no code changes yet)
**Author:** Patrick + Claude

## Problem

Modelo has three entry points into settings, split across **two different
surfaces** showing the same `SettingsView`:

| Entry point | What happens |
|---|---|
| ⌘, / app menu "Settings…" | `Settings` scene opens a **standalone window** (`ModeloApp.swift:170-191`) |
| Sidebar "Settings" row | Main window detail pane routes to `SettingsView(isInline: true)` (`ContentView.swift`) |
| Model picker footer "Manage models" | `SettingsLink` opens the **window** (`ModelPickerView.swift:311`) |

That split causes real problems:

- **Split-brain UX.** Both surfaces can be open at once, editing the same data,
  each remembering its own selected tab (`@SceneStorage` is per-scene).
- **Duplicated wiring.** The `Settings` scene doesn't inherit the main window's
  environment, so all eight observable objects plus the model container are
  re-injected by hand; a missed one is a crash (this has already happened once — see the comment at
  `ModeloApp.swift:173-177`).
- **The Memory-tab window blowup.** Every settings tab wraps its content in a
  `ScrollView` except `memoryTab`, which is a bare `VStack` holding
  `MemoryManagerView`. That view's `TextEditor` and `maxHeight: .infinity`
  frames report an effectively unbounded *ideal* height. The Settings window
  re-measures itself to fit content on tab switch, so selecting Memory grows
  the window past the screen. Commit `bbe8411` made the window resizable
  (`.contentMinSize`) but didn't bound what the content asks for. The main
  window is immune — it is user-sized and never chases content.

## Decision

**In-app only.** Remove the `Settings` scene entirely; every entry point routes
the main window's detail pane to the existing `.settings` sidebar route.

Rationale: Modelo's settings aren't lightweight preferences — endpoints, MCP
servers, presets, and the memory editor are management surfaces that already
live as a first-class sidebar route, like Reports and Status. Deleting the
window also deletes the blowup bug and the duplicated environment wiring at
the root.

## Goals

- Exactly one settings surface: the detail-pane `SettingsView`.
- ⌘, keeps working everywhere, **including menu-bar-only mode** (the app
  deliberately keeps running with the main window closed).
- "Manage models" lands on the **Endpoints** tab, not whatever tab was last open.
- The Memory-tab window blowup is gone.

## Non-goals (this pass)

- No redesign of the settings tabs or their content.
- No settings entry added to the menu-bar popover (none exists today).
- No "Settings" item in the Go menu (⌘, plus the app menu item suffice).

## Design

1. **Remove the `Settings` scene** from `ModeloApp.swift`, including its eight
   `.environment(...)` injections, `.modelContainer`, `.toolbarBackground`, and
   `.windowResizability(.contentMinSize)`.

2. **⌘, becomes a routed menu item.** `CommandGroup(replacing: .appSettings)`
   inserts our own "Settings…" button with `.keyboardShortcut(",")` in the
   standard app-menu position. It navigates via a new `goToSettings` action on
   the existing `ModeloCommands` focused-value bundle (`ContentView.swift:22`),
   exactly like the Go menu commands.
   - Main window focused → route it to `.settings`.
   - No focused window (menu-bar-only mode) → reopen the main window, then land
     on settings — the same "reopen and route" idea the notification-tap flow
     already uses (`notifier.tappedConversation`, consumed in `onAppear`).
   - **Constraint:** must never spawn a second main window when one already
     exists. Modelo is deliberately single-window (File ▸ New Window is replaced
     by New Chat). Mechanism — `openWindow(id:)` on an id'd `WindowGroup` vs.
     ordering an existing `NSWindow` front — is decided in the implementation
     plan, but the behavior above is the requirement.

3. **"Manage models" routes to Settings ▸ Endpoints.** Replace the
   `SettingsLink` in `ModelPickerView` with a custom environment action
   (declared with the `@Entry` macro) that `ContentView` injects. Invoking it
   dismisses the picker popover, routes to `.settings`, and selects the
   Endpoints tab. Tab targeting: `ContentView` hands `SettingsView` a one-shot
   pending-tab override that wins over the `@SceneStorage` selection when set,
   then clears.

4. **`SettingsView` loses its dual personality.** Delete the `isInline`
   property, the window-sized `frame` branch, and the window-only
   `.toolbarBackground` override (`SettingsView.swift:41-52`). The view is
   always the detail-pane variant.

5. **Memory tab verification.** With the window gone the blowup cannot occur,
   but acceptance includes checking Settings ▸ Memory inline at the minimum
   window size: the edit pane, memory list, and Add Memory button must all stay
   within the pane (the detail pane bounds `maxHeight: .infinity` correctly).

### Accepted trade-off

⌘, now replaces whatever is in the detail pane (e.g. an active chat) instead of
opening beside it. Getting back is a sidebar click — the same cost as leaving
Reports or Status today. Streaming turns survive navigation because
`ChatSessionStore` owns them, so nothing is interrupted.

## Acceptance criteria

- [ ] ⌘, with the main window open shows settings in the detail pane.
- [ ] ⌘, in menu-bar-only mode reopens the main window directly onto settings.
- [ ] ⌘, never creates a second main window.
- [ ] The app menu still shows "Settings…" with the ⌘, key equivalent.
- [ ] Sidebar "Settings" row behaves exactly as before.
- [ ] "Manage models" in the model picker closes the picker and lands on
      Settings ▸ Endpoints.
- [ ] No standalone Settings window can be opened by any path.
- [ ] Settings ▸ Memory renders within the pane at minimum window size.
- [ ] `SettingsView` has no `isInline` parameter; no dead window-variant code
      remains.

## Testing

Build verification (`xcodebuild -project Modelo.xcodeproj -scheme Modelo
-destination 'platform=macOS' build`), then the manual acceptance pass above.
No new unit tests: this is UI wiring with no extractable logic beyond the
pending-tab handoff, which the manual pass covers.
