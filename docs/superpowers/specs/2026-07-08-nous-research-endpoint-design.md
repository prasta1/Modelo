# Nous Research Endpoint — Design Spec

**Date:** 2026-07-08  
**Status:** Approved

## Overview

Add Nous Research as a first-class dedicated cloud inference endpoint, mirroring the `.openRouter` pattern: a named `ServerKind` case with a hardcoded base URL, so users only need to paste an API key — no URL to type.

Nous Research API base URL: `https://inference-api.nousresearch.com/v1`  
Wire format: OpenAI-compatible (`/models`, `/chat/completions`, bearer auth).

---

## Files Changed

### 1. `Modelo/Services/Endpoint.swift` — ServerKind + Endpoint constants

**`ServerKind` enum** — new case:
```swift
case nous = "nousFixed"
```
Raw value `"nousFixed"` mirrors the OpenRouter pattern (`"openRouterFixed"`) and preserves back-compat for any future migration.

Updated computed properties:
- `isLocal`: `.nous` → `false`
- `displayName`: `.nous` → `"Nous Research"`
- `defaultPort`: `.nous` → `0`

**`Endpoint` extension** — new constant:
```swift
static let nousBaseURL = "https://inference-api.nousresearch.com/v1"
```

---

### 2. `Modelo/Models/Server.swift` — baseURL

`Server.baseURL` switch gets a new arm:
```swift
case .nous: Endpoint.nousBaseURL
```
`server.host` is unused for `.nous` (URL is hardcoded), consistent with `.openRouter`.

---

### 3. `Modelo/Services/LMStudioClient.swift` — 4 switch statements

`.nous` slots into the `.cloudAPI, .openRouter` group in all four locations:

| Method | Path used | Change |
|--------|-----------|--------|
| `fetchModels` | `/models` + `ModelsResponse` decode | add `.nous` to `.cloudAPI` arm |
| `probeReachable` | `/models` | add `.nous` to `.cloudAPI, .openRouter` arm |
| `probeDetailed` | `/models` | add `.nous` to `.cloudAPI, .openRouter` arm |
| `streamOnce` (chatPath) | `/chat/completions` | add `.nous` to `.cloudAPI, .openRouter` arm |

No new networking code needed — Nous is a standard OpenAI-compatible cloud API.

---

### 4. `Modelo/Services/ReachabilityMonitor.swift`

`pollInterval`: add `.nous` to the `case .cloudAPI, .openRouter` arm → 30-second fixed cadence (same as other cloud providers, which don't have sleep state to back off from).

---

### 5. `Modelo/Views/ServerRow.swift`

`subtitle` switch — new case:
```swift
case .nous:
    return "via API"
```

---

### 6. `Modelo/Views/ServerStatsView.swift`

`hostSubtitle` switch — new case:
```swift
case .nous: return "inference-api.nousresearch.com"
```

---

### 7. `Modelo/Settings/SettingsView.swift` — two changes

**a) `addNousServer()` helper:**
```swift
private func addNousServer() {
    let nextOrder = (servers.map(\.sortOrder).max() ?? 0) + 1
    let server = Server(label: "Nous Research", host: "", port: 0,
                        sortOrder: nextOrder, kind: .nous)
    context.insert(server)
    context.saveOrLog()
    newlyAddedID = server.id
}
```

**b) Cloud API submenu** — new button above the "Custom…" divider:
```swift
Button("Nous Research") { addNousServer() }
Divider()
```

**c) `CloudServerSettingsRow`** — hide the Base URL field for fixed-URL kinds.

Add a helper on `ServerKind`:
```swift
/// True when the base URL is hardcoded and not user-configurable (e.g. .openRouter, .nous).
var hasFixedURL: Bool {
    switch self {
    case .openRouter, .nous: return true
    default: return false
    }
}
```

In `CloudServerSettingsRow.body`, wrap the `FieldGroup(caption: "Base URL")` block in `if !server.kind.hasFixedURL { … }`. This fixes a latent gap for OpenRouter too (previously the field showed empty/confusing).

---

### 8. `Modelo/ModeloTests/EndpointTests.swift` — 2 new tests

```swift
func test_serverKind_nous_rawValue() {
    XCTAssertEqual(ServerKind.nous.rawValue, "nousFixed")
    XCTAssertEqual(ServerKind.nous.displayName, "Nous Research")
    XCTAssertFalse(ServerKind.nous.isLocal)
}

func test_baseURL_nous_isHardcoded() {
    let s = Server(label: "Nous", host: "", port: 0, kind: .nous)
    XCTAssertEqual(s.baseURL, Endpoint.nousBaseURL)
}
```

---

## What is NOT changed

- No new `ChatProvider` implementation — Nous uses the same `LMStudioClient` as all OpenAI-compatible clouds.
- No new Keychain account format — reuses `Endpoint.keychainAccount(for:)` (the "openrouter:" prefix is a misnomer from history, not provider-specific).
- No migration — `SwiftData` only reads the raw string; `"nousFixed"` is a new value so no existing records are affected.
- No change to `ServerMonitor`, model load/unload, GPU/Prometheus paths — none apply to cloud endpoints.

---

## Scope

8 files, ~30 lines net added. No new types, no new networking code. Exhaustive switch statements catch any missed location at compile time.
