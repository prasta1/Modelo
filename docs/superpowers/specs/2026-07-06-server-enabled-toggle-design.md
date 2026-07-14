# Per-Server Enabled Toggle

**Date:** 2026-07-06
**Status:** Approved

## Problem

Servers configured in Modelo always appear in the chat view's server picker and are
always polled (reachability, model discovery, GPU/Prometheus metrics). Machines that
are usually off — a laptop, a lab box — clutter the picker and generate pointless
network noise. The user wants to keep such servers configured but park them.

## Decisions (from brainstorming)

- **Semantics: fully dormant.** Disabling a server removes it from the chat picker
  AND stops all background contact: reachability probes, model list refreshes, and
  metrics polling (GPU agent, macmon, Prometheus, LM Studio/exo monitor). One switch,
  one meaning.
- **Storage: a field on the model.** `isEnabled` lives on the `Server` SwiftData
  record — one source of truth that lives and dies with the server. (Rejected:
  hidden-ID set in UserDefaults — split truth, orphan cleanup; picker-only filter —
  contradicts dormant semantics.)
- **Stale chats fail quietly.** A conversation bound to a disabled server keeps its
  history; sending fails the same way it does today when a server disappears
  (`boundServer == nil`). No new banner or re-enable affordance.
- **Toggle placement: prominent.** Top of each server's settings row, not buried in
  the Advanced section — it will be flipped routinely.

## Design

### 1. Data model

Add to `Modelo/Models/Server.swift`:

```swift
var isEnabled: Bool = true
```

SwiftData treats this as a lightweight migration; existing rows default to `true`,
so behavior is unchanged until a user flips a switch. The name is `isEnabled` (not
`hideFromPicker`) because it governs polling, not just visibility.

### 2. Enforcement — filter at the seams

The monitor services keep their `start(servers:)` API untouched; callers pass a
filtered array (`servers.filter(\.isEnabled)`):

| Seam | Location | Effect |
|---|---|---|
| Monitor startup | `ModeloApp.swift:249-252` | Reachability, server, GPU, Prometheus monitors never see disabled servers |
| Monitor restart | `ContentView.swift:159-162` | Same, when the server set changes |
| Model discovery | `ContentView.swift:487` (`refreshModels`) | Disabled servers produce no `DiscoveredModel`s → picker pills and model list empty out downstream, no picker changes needed |
| Discovery key | `ContentView.swift:432` (`serverDiscoveryKey`) | Append `isEnabled` to the per-server key string so toggling immediately re-runs discovery and restarts monitors — live effect, no relaunch |
| Menu bar discovery | `MenuBarChatView.swift:294` | Menu bar chat also skips disabled servers |
| Status surfaces | `StatusView.swift:26,65` | Disabled servers excluded from the status list and "live" count |

Settings (`SettingsView.swift`) intentionally still lists **all** servers — that is
where disabled servers are managed — and `ServerProbeRow` continues to probe there,
so the user can check whether a parked machine is back before re-enabling it.
Settings probing is user-initiated (the window is open), which does not violate the
dormant contract for background polling.

### 3. Settings UI

- A `Toggle` bound to `server.isEnabled` at the top of `ServerSettingsRow`
  (~line 849 area) and `CloudServerSettingsRow` (~line 1346 area), adjacent to the
  label/status LED.
- When off, the row's detail controls render dimmed (`.opacity` + `.disabled` on
  the detail section). Delete remains available.

### 4. Edge cases

- **Chat bound to a disabled server:** existing `boundServer == nil` fallback in
  `ChatView.swift:86-89` handles it; no new code.
- **Launcher's transient `pickedModel`:** cleared when its server becomes disabled
  (guard where `discovered` updates in `ContentView`), so the next send can't
  target a dormant server.
- **All servers disabled:** picker shows its existing empty state.
- **Toggle flipped while a request is in flight:** in-flight requests complete;
  dormancy applies from the next poll/discovery cycle.

### 5. Testing

In `ModeloTests` (in-memory SwiftData, pattern per `ServerRegistryTests.swift`):

- New `Server` defaults to `isEnabled == true`.
- Filtering excludes disabled servers (extract into a small testable helper only if
  it falls out naturally — no forced abstraction).
- `serverDiscoveryKey` changes when `isEnabled` flips (drives the live-toggle behavior).

Manual pass: toggle off → picker pills, models, and metrics for that server
disappear without relaunch; toggle on → everything returns.

## Scope

One branch (`feature/server-enabled-toggle`), one reviewable diff, well under the
1500-line ceiling in AGENTS.md. Schema + UI change → pauses for human review
before merge.
