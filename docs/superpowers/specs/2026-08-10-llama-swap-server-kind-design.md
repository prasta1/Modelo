# llama-swap Dedicated ServerKind — Design Spec

**Date:** 2026-08-10  
**Branch:** `feature/llama-swap-kind`

---

## Background

`ServerKind.llamaCpp` (raw value `"llamaSwap"`) currently covers both raw llama.cpp servers and llama-swap proxy instances. The kind is displayed as "llama.cpp" with a parenthetical hint for llama-swap users. This conflation makes llama-swap a second-class citizen in the UI and prevents it from having its own distinct display name, icon, and setup guidance.

---

## Goal

Add `llamaSwap` as a dedicated `ServerKind` case, surfaced as a peer of `llamaCpp` in the "Add Endpoint → Local" menu. The two kinds are wire-identical (both use OpenAI-compatible `/v1` endpoints) — they differ only in label, icon, and setup text.

---

## Non-Goals

- No new API endpoints or network behavior. llama-swap and llama.cpp share the same `/v1/models` and `/v1/chat/completions` paths.
- No migration of existing stored servers. Existing servers with raw value `"llamaSwap"` continue to decode to `llamaCpp` (llama.cpp). Only servers explicitly added via the new "llama-swap" menu entry get the new `llamaSwap` kind.
- No llama-swap-specific API features (slots, groups, health endpoint) in this iteration.

---

## Design

### New case

```swift
// Endpoint.swift — ServerKind enum
/// Dedicated llama-swap proxy kind. Wire-identical to llamaCpp but
/// displayed as "llama-swap" with a proxy-specific setup hint.
case llamaSwap = "llamaSwapProxy"
```

Raw value `"llamaSwapProxy"` is fresh — it doesn't conflict with the legacy `"llamaSwap"` raw value on `llamaCpp`.

### Properties

| Property | `llamaCpp` (unchanged) | `llamaSwap` (new) |
|---|---|---|
| `rawValue` | `"llamaSwap"` | `"llamaSwapProxy"` |
| `displayName` | `"llama.cpp"` | `"llama-swap"` |
| `defaultPort` | `8080` | `8080` |
| `isLocal` | `true` | `true` |
| `hasFixedURL` | `false` | `false` |
| SF Symbol | `"terminal"` | `"shuffle"` |

### Migration

None required. All existing stored records carry raw value `"llamaSwap"` (the old `llamaCpp` raw value) and continue to deserialise to `llamaCpp`. No SwiftData schema migration is needed.

---

## Files Changed

### 1. `Endpoint.swift`

- Add `case llamaSwap = "llamaSwapProxy"` after `llamaCpp`.
- Update doc comment on the enum to describe both `llamaCpp` and `llamaSwap`.
- Add `.llamaSwap` to `isLocal` (`true`).
- Add `case .llamaSwap: return "llama-swap"` to `displayName`.
- Add `case .llamaSwap: return 8080` to `defaultPort`.
- `hasFixedURL` defaults to `false` via the `default` branch — no change needed.

### 2. `Server.swift`

- Add `.llamaSwap` to the `baseURL` local branch alongside `.llamaCpp`.

### 3. `LMStudioClient.swift`

Four switch branches, each needs `.llamaSwap` added alongside `.llamaCpp`:

| Method | Current branch | Change |
|---|---|---|
| `fetchModels` | `case .llamaCpp, .oMLX:` | `case .llamaCpp, .llamaSwap, .oMLX:` |
| `probeReachable` | `case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:` | add `.llamaSwap` |
| `probeDetailed` | `case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:` | add `.llamaSwap` |
| `streamOnce` | `case .lmStudio, .llamaCpp, .oMLX, .exo:` | add `.llamaSwap` |

### 4. `ReachabilityMonitor.swift`

- `pollInterval`: Add `.llamaSwap` to `case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:`.

### 5. `ServerRow.swift`

- `subtitle`: Add `.llamaSwap` to `case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:`.

### 6. `ServerStatsView.swift`

- Local address branch: Add `.llamaSwap` to `case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:`.

### 7. `SettingsView.swift`

Two additions:

**`localIcon(for:)`** — add:
```swift
case .llamaSwap: return "shuffle"
```

**`LocalSetupHint.hint`** — add:
```swift
case .llamaSwap:
    return "llama-swap is a reverse proxy that manages multiple llama.cpp backends. Point to your llama-swap host and port (default 8080). See github.com/mostlygeek/llama-swap for setup."
```

### 8. `EndpointTests.swift`

- Update `test_serverKind_localCases` expected array to `[.lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo]` (declaration order; `llamaSwap` inserted immediately after `llamaCpp`).
- Add `test_serverKind_llamaSwapRawValue` asserting `ServerKind(rawValue: "llamaSwapProxy") == .llamaSwap` and `ServerKind.llamaSwap.rawValue == "llamaSwapProxy"`.
- Verify existing `test_serverKind_llamaSwapRawValue_decodesToLlamaCpp` still passes (it asserts `"llamaSwap"` decodes to `.llamaCpp` — unchanged).

---

## Ordering

Changes can be applied in any order since they're all additive. Recommended: `Endpoint.swift` first (defines the case), then compile-check catches every switch that needs updating.

---

## Out of Scope

- llama-swap `/health` health-check endpoint (could replace `/v1/models` probe in a future iteration).
- llama-swap model group/slot display in the model browser.
- Per-kind Prometheus URL auto-suggestion.
