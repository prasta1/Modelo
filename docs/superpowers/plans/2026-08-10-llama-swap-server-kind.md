# llama-swap Dedicated ServerKind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `llamaSwap = "llamaSwapProxy"` as a first-class `ServerKind` case, surfacing llama-swap as its own entry in the "Add Endpoint → Local" menu alongside the existing `llamaCpp` (llama.cpp) case.

**Architecture:** All changes are additive — a new enum case dropped in alongside `llamaCpp`. The two kinds share identical wire behavior (`/v1/models`, `/v1/chat/completions`) so every `LMStudioClient` switch arm just adds `.llamaSwap` next to `.llamaCpp`. No data migration needed; existing servers stored as raw value `"llamaSwap"` keep decoding to `llamaCpp`.

**Tech Stack:** Swift, SwiftData, SwiftUI, XCTest

---

## File Map

| File | Change |
|---|---|
| `Modelo/ModeloTests/EndpointTests.swift` | Add two tests for new case; update localCases assertion |
| `Modelo/Modelo/Services/Endpoint.swift` | Add `case llamaSwap`, update enum doc + `isLocal`, `displayName`, `defaultPort` |
| `Modelo/Modelo/Models/Server.swift` | Add `.llamaSwap` to `baseURL` local branch |
| `Modelo/Modelo/Services/LMStudioClient.swift` | Add `.llamaSwap` to 4 switch arms |
| `Modelo/Modelo/Services/ReachabilityMonitor.swift` | Add `.llamaSwap` to `pollInterval` |
| `Modelo/Modelo/Views/ServerRow.swift` | Add `.llamaSwap` to `subtitle` |
| `Modelo/Modelo/Views/ServerStatsView.swift` | Add `.llamaSwap` to `hostSubtitle` |
| `Modelo/Modelo/Settings/SettingsView.swift` | Add icon + setup hint for `.llamaSwap` |

---

## Task 1: Write failing tests

**Files:**
- Modify: `Modelo/ModeloTests/EndpointTests.swift`

- [ ] **Step 1: Update `test_serverKind_localCases_areTheLocalRuntimes` to expect the new case**

In `EndpointTests.swift`, find the test at line 46 and replace its first assertion:

```swift
// Before
XCTAssertEqual(ServerKind.localCases, [.lmStudio, .llamaCpp, .oMLX, .ollama, .exo])

// After
XCTAssertEqual(ServerKind.localCases, [.lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo])
```

The rest of that test (`.oMLX.isLocal`, `.exo.isLocal`, `.cloudAPI.isLocal` assertions) stays unchanged.

- [ ] **Step 2: Add a new test for the `llamaSwap` case properties**

Add this test after `test_serverKind_defaultPorts` (around line 75):

```swift
func test_serverKind_llamaSwap_rawValueAndProperties() {
    XCTAssertEqual(ServerKind(rawValue: "llamaSwapProxy"), .llamaSwap)
    XCTAssertEqual(ServerKind.llamaSwap.rawValue, "llamaSwapProxy")
    XCTAssertEqual(ServerKind.llamaSwap.displayName, "llama-swap")
    XCTAssertEqual(ServerKind.llamaSwap.defaultPort, 8080)
    XCTAssertTrue(ServerKind.llamaSwap.isLocal)
    XCTAssertFalse(ServerKind.llamaSwap.hasFixedURL)
}
```

- [ ] **Step 3: Add a baseURL test for the new case**

Add after the test above:

```swift
func test_baseURL_llamaSwap_usesHostPort() {
    let s = Server(label: "llama-swap", host: "localhost", port: 8080, kind: .llamaSwap)
    XCTAssertEqual(s.baseURL, "http://localhost:8080")
}
```

- [ ] **Step 4: Confirm the build fails with a compile error**

The test file now references `.llamaSwap` which doesn't exist yet. Build should fail with:
`error: type 'ServerKind' has no member 'llamaSwap'`

This confirms the tests are correctly gated on the implementation.

---

## Task 2: Add `llamaSwap` to `Endpoint.swift`

**Files:**
- Modify: `Modelo/Modelo/Services/Endpoint.swift`

- [ ] **Step 1: Update the enum doc comment**

Replace lines 4–16 (the `///` block before `enum ServerKind`) with:

```swift
/// Which kind of backend a `Server` row points at.
/// - `lmStudio`: a local LM Studio machine (host:port over HTTP, no auth, rich `/api/v0`).
/// - `llamaCpp`: a raw llama.cpp server (llama-server; host:port, OpenAI-compatible `/v1`, no `/api/v0`).
/// - `llamaSwap`: a llama-swap reverse proxy that routes model requests to multiple llama.cpp
///   backends. Same wire shape as `llamaCpp`; distinct in label, icon, and setup guidance.
/// - `oMLX`: a local oMLX server (omlx.ai) — an Apple-silicon MLX runtime. Same wire
///   shape as `llamaCpp` (host:port, OpenAI-compatible `/v1`); distinct only in label/port.
/// - `cloudAPI`: any OpenAI-compatible cloud endpoint (user-supplied HTTPS base URL, bearer auth).
/// - `openRouter`: hardcoded OpenRouter cloud endpoint — user supplies only the API key.
/// - `nous`: hardcoded Nous Research inference endpoint — user supplies only the API key.
///
/// `lmStudio`, `llamaCpp`, `llamaSwap`, `oMLX`, `ollama`, and `exo` are *local* (self-hosted) —
/// they run on hardware you control and can have a `modelo-tap` GPU agent next to them.
```

- [ ] **Step 2: Add the new case after `llamaCpp`**

In the enum body, after line 20 (`case llamaCpp = "llamaSwap"`), insert:

```swift
    /// Dedicated llama-swap proxy kind. Wire-identical to llamaCpp but
    /// displayed as "llama-swap" with a proxy-specific setup hint.
    case llamaSwap = "llamaSwapProxy"
```

- [ ] **Step 3: Add `.llamaSwap` to `isLocal`**

Replace the `isLocal` switch arm (currently line 39):

```swift
// Before
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: true

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: true
```

- [ ] **Step 4: Add `llamaSwap` display name**

In the `displayName` switch, after `case .llamaCpp: return "llama.cpp"`, add:

```swift
case .llamaSwap:  return "llama-swap"
```

- [ ] **Step 5: Add `llamaSwap` default port**

In the `defaultPort` switch, after `case .llamaCpp: return 8080`, add:

```swift
case .llamaSwap:                    return 8080
```

- [ ] **Step 6: Verify the build now fails only on the files that haven't been updated yet**

Expected: compile errors in `Server.swift`, `LMStudioClient.swift`, `ReachabilityMonitor.swift`, `ServerRow.swift`, `ServerStatsView.swift`, and `SettingsView.swift` — each complaining about non-exhaustive switches. No errors should remain in `Endpoint.swift` itself.

---

## Task 3: Fix one-liner switch arms (Server, ReachabilityMonitor, ServerRow, ServerStatsView)

**Files:**
- Modify: `Modelo/Modelo/Models/Server.swift` (line 61)
- Modify: `Modelo/Modelo/Services/ReachabilityMonitor.swift` (line 46)
- Modify: `Modelo/Modelo/Views/ServerRow.swift` (line 27)
- Modify: `Modelo/Modelo/Views/ServerStatsView.swift` (line 214)

Each of these is a single grouped `case` arm that needs `.llamaSwap` inserted. Make the changes below.

- [ ] **Step 1: `Server.swift` — `baseURL`**

```swift
// Before (line 61)
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: "http://\(Server.normalizedHost(host)):\(port)"

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: "http://\(Server.normalizedHost(host)):\(port)"
```

- [ ] **Step 2: `ReachabilityMonitor.swift` — `pollInterval`**

```swift
// Before (line 46)
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: return status == .online ? .seconds(10) : .seconds(30)

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: return status == .online ? .seconds(10) : .seconds(30)
```

- [ ] **Step 3: `ServerRow.swift` — `subtitle`**

```swift
// Before (line 27)
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo:

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo:
```

- [ ] **Step 4: `ServerStatsView.swift` — `hostSubtitle`**

```swift
// Before (line 214)
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: return "\(server.host):\(server.port)"

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: return "\(server.host):\(server.port)"
```

- [ ] **Step 5: Verify remaining compile errors are only in `LMStudioClient.swift` and `SettingsView.swift`**

---

## Task 4: Fix `LMStudioClient.swift` (4 switch arms)

**Files:**
- Modify: `Modelo/Modelo/Services/LMStudioClient.swift`

All four arms are in the same file. The line numbers below are approximate — use the surrounding context to find each one.

- [ ] **Step 1: `fetchModels` — the `llamaCpp, .oMLX` arm (around line 66)**

```swift
// Before
case .llamaCpp, .oMLX:
    // Generic local OpenAI-compatible servers (llama.cpp/llama-swap, oMLX): no /api/v0.
    return try await fetch(path: "/v1/models", endpoint: endpoint)
        .filter { !$0.isEmbeddingModel }

// After
case .llamaCpp, .llamaSwap, .oMLX:
    // Generic local OpenAI-compatible servers (llama.cpp, llama-swap, oMLX): no /api/v0.
    return try await fetch(path: "/v1/models", endpoint: endpoint)
        .filter { !$0.isEmbeddingModel }
```

- [ ] **Step 2: `probeReachable` — the local path arm (around line 117)**

```swift
// Before
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: path = "/v1/models"

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: path = "/v1/models"
```

- [ ] **Step 3: `probeDetailed` — the local path arm (around line 135)**

```swift
// Before
case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: path = "/v1/models"

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .ollama, .exo: path = "/v1/models"
```

- [ ] **Step 4: `streamOnce` — the chat path arm (around line 317)**

```swift
// Before
case .lmStudio, .llamaCpp, .oMLX, .exo: chatPath = "/v1/chat/completions"

// After
case .lmStudio, .llamaCpp, .llamaSwap, .oMLX, .exo: chatPath = "/v1/chat/completions"
```

- [ ] **Step 5: Verify remaining compile errors are only in `SettingsView.swift`**

---

## Task 5: Add icon and setup hint in `SettingsView.swift`

**Files:**
- Modify: `Modelo/Modelo/Settings/SettingsView.swift`

- [ ] **Step 1: Add the llama-swap icon to `localIcon(for:)`**

Find the `localIcon(for:)` function (around line 269). Add a case for `.llamaSwap`:

```swift
private func localIcon(for kind: ServerKind) -> String {
    switch kind {
    case .lmStudio: return "server.rack"
    case .llamaCpp: return "terminal"
    case .llamaSwap: return "shuffle"          // ← add this line
    case .oMLX:     return "cpu"
    case .ollama:   return "cylinder"
    case .exo:      return "point.3.connected.trianglepath.dotted"
    default:        return "server.rack"
    }
}
```

- [ ] **Step 2: Add the llama-swap setup hint to `LocalSetupHint.hint`**

Find the `hint` computed property in `LocalSetupHint` (around line 1185). Add a case for `.llamaSwap` after the `llamaCpp` case:

```swift
case .llamaSwap:
    return "llama-swap is a reverse proxy that manages multiple llama.cpp backends. Point to your llama-swap host and port (default 8080). See github.com/mostlygeek/llama-swap for setup."
```

The full `hint` switch after the change:

```swift
private var hint: String {
    switch kind {
    case .lmStudio:
        return "Install LM Studio from lmstudio.ai. Load a model in the Models tab, then start the local server from the Developer tab. Default port: 1234."
    case .ollama:
        return "Install Ollama from ollama.com, then pull a model: ollama pull llama3.2. The server starts automatically. Default port: 11434."
    case .llamaCpp:
        return "Run the server: llama-server -m model.gguf --port 8080. Default port: 8080."
    case .llamaSwap:
        return "llama-swap is a reverse proxy that manages multiple llama.cpp backends. Point to your llama-swap host and port (default 8080). See github.com/mostlygeek/llama-swap for setup."
    case .oMLX:
        return "Install oMLX (Apple Silicon) from omlx.ai. Load a model in the app and tap Start Server. Default port: 8000."
    case .exo:
        return "Run exo (exolabs.net) on this or another Mac. Add its host and port (default 52415). Models must be launched in exo's dashboard before you can chat with them."
    case .cloudAPI, .openRouter, .nous:
        return ""
    }
}
```

Note: also remove "llama-swap users: point to your proxy's port instead of 8080." from the `llamaCpp` hint since llama-swap now has its own entry.

- [ ] **Step 3: Confirm the project builds with no errors**

---

## Task 6: Run tests, verify, and commit

- [ ] **Step 1: Run `EndpointTests`**

```bash
xcodebuild test \
  -project Modelo/Modelo.xcodeproj \
  -scheme Modelo \
  -destination 'platform=macOS' \
  -only-testing:ModeloTests/EndpointTests \
  2>&1 | grep -E "passed|failed|error:"
```

Expected output: all tests in `EndpointTests` pass, including:
- `test_serverKind_llamaSwap_rawValueAndProperties` — PASS
- `test_baseURL_llamaSwap_usesHostPort` — PASS
- `test_serverKind_localCases_areTheLocalRuntimes` — PASS (now expects 6-element array)
- `test_serverKind_llamaSwapRawValue_decodesToLlamaCpp` — PASS (unchanged; `"llamaSwap"` still → `.llamaCpp`)

- [ ] **Step 2: Run the full test suite**

```bash
xcodebuild test \
  -project Modelo/Modelo.xcodeproj \
  -scheme Modelo \
  -destination 'platform=macOS' \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: no failures.

- [ ] **Step 3: Verify in the Settings UI that "llama-swap" appears in Add Endpoint → Local**

Launch the app, open Settings → Endpoints, click "Add Endpoint." Under "Local" the menu should now show:
- LM Studio
- llama.cpp
- **llama-swap** ← new, with shuffle icon
- oMLX
- Ollama
- exo

- [ ] **Step 4: Commit**

```bash
git add \
  Modelo/Modelo/Services/Endpoint.swift \
  Modelo/Modelo/Models/Server.swift \
  Modelo/Modelo/Services/LMStudioClient.swift \
  Modelo/Modelo/Services/ReachabilityMonitor.swift \
  Modelo/Modelo/Views/ServerRow.swift \
  Modelo/Modelo/Views/ServerStatsView.swift \
  Modelo/Modelo/Settings/SettingsView.swift \
  Modelo/ModeloTests/EndpointTests.swift
git commit -m "feat: add llama-swap as a dedicated ServerKind

Separates llama-swap from the generic llamaCpp case so users get a
distinct entry in Add Endpoint with its own icon, name, and setup hint.
Existing llamaCpp servers (stored raw value 'llamaSwap') are unaffected.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
