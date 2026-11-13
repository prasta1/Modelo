# Apple Intelligence Provider (Tier 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apple's on-device model (Foundation Models) appears as an auto-added, zero-setup provider in Modelo's model picker, with text chat working in every surface that uses `LMStudioClient`.

**Architecture:** New `ServerKind.appleIntelligence` plus a dedicated `AppleIntelligenceClient` (peer to `ExoClient`). `LMStudioClient.fetchModels` / `probeReachable` / `streamChat` forward that kind to it, so the main chat, the menu-bar quick chat, `Benchmark` and `ReachabilityMonitor` all pick it up unchanged. History mapping, trimming and snapshot→delta diffing live in a pure, framework-free `AppleIntelligenceRequest` so they unit-test without the model.

**Tech Stack:** Swift 5 mode / SwiftUI / SwiftData, Foundation Models (macOS 26+, behind `#available`), XcodeGen (`project.yml`), XCTest (`@testable import Modelo`).

**Spec:** `docs/specs/2026-10-28-apple-foundation-models.md`

## Global Constraints

- Deployment target stays **macOS 14.0**. Every Foundation Models symbol sits behind `@available(macOS 26, *)` / `#available(macOS 26, *)`.
- Use **only macOS 26 Foundation Models APIs.** CI (`release.yml`) runs on `macos-26`; macOS 27 symbols (`contextSize`, `LanguageModelError`, image attachments) won't compile there even behind `#available`.
- Raw value `"appleIntelligence"`; display name `"Apple Intelligence"`; base URL sentinel `"apple-intelligence://on-device"`; model id `"apple-on-device"`.
- Context window **4,096 tokens**. Response reserve = `sampling.maxTokens ?? 1024`.
- No session caching: rebuild the `LanguageModelSession` from a `Transcript` every turn.
- No SwiftData schema change. No new dependencies.
- Build check: the `xcodebuild … CODE_SIGNING_ALLOWED=NO build` command in `AGENTS.md`; tests: the same with `test`. Run `xcodegen generate` after adding files.

## Review Focus

1. **Conversation that used tools on another model, then switched to Apple Intelligence.** `tool` messages and assistant messages that carry only `tool_calls` must be skipped, not sent as empty turns. Pinned in Task 2.
2. **System prompt + last user message alone over budget.** Send them anyway (nothing left to trim) and let the framework's context error surface as readable text. Must not crash or loop. Pinned in Task 2 (no-trim case) and Task 3 (error mapping).
3. **Image attachments in history.** Text blocks are kept and images dropped. A turn that was image-only is skipped. Pinned in Task 2.
4. **Stop mid-stream.** Cancelling the consuming task must end generation and keep the partial reply (same contract as HTTP providers). Manual check in Task 6.
5. **Apple Intelligence switched off after the row exists.** The row stays, the picker drops the model on the next reachability poll, and Settings shows the reason. Manual check in Task 6.

---

### Task 1: `ServerKind.appleIntelligence` and exhaustive-switch sites

**Files:**
- Modify: `Modelo/Services/Endpoint.swift` (enum doc comment, `isLocal`, `displayName`, `defaultPort`, `hasFixedURL`, `localCases`; add `static let appleIntelligenceBaseURL`)
- Modify: `Modelo/Models/Server.swift:58-68` (`baseURL`)
- Modify: `Modelo/Services/LMStudioClient.swift` (`fetchModels` `:50`, `probeReachable` `:127`, `probeDetailed` `:179`, chat path `:434`): temporary placeholders, replaced in Task 3
- Modify: `Modelo/Services/ReachabilityMonitor.swift:46`, `Modelo/Settings/SettingsView.swift:290` (icon) and `:1371` (help text), `Modelo/Views/ServerStatsView.swift:216`
- Test: `ModeloTests/EndpointTests.swift`

**Interfaces:**
- Produces: `ServerKind.appleIntelligence`, `Endpoint.appleIntelligenceBaseURL: String`. `localCases` excludes the new kind, because it feeds the runtime pickers, `NetworkScanner`'s port list and `isDefaultLocalPort`, and port 0 is meaningless there.

- [ ] **Step 1: Write failing tests** in `EndpointTests`:

```swift
func test_appleIntelligence_kindProperties() {
    let k = ServerKind.appleIntelligence
    XCTAssertEqual(k.rawValue, "appleIntelligence")
    XCTAssertEqual(k.displayName, "Apple Intelligence")
    XCTAssertTrue(k.isLocal)
    XCTAssertTrue(k.hasFixedURL)
    XCTAssertEqual(k.defaultPort, 0)
    XCTAssertFalse(ServerKind.localCases.contains(.appleIntelligence))
}

func test_appleIntelligence_baseURLIsSentinel() {
    let s = Server(label: "Apple Intelligence", host: "", port: 0, kind: .appleIntelligence)
    XCTAssertEqual(s.baseURL, "apple-intelligence://on-device")
}
```

- [ ] **Step 2: Run, expect a compile failure** (`appleIntelligence` is not a member).
- [ ] **Step 3: Add the case and fix every site the compiler flags.** Values: icon `"apple.intelligence"`; help text `""` (the row in Task 5 has no host form); `ServerStatsView` host label `"On-device"`; reachability interval `.seconds(60)` regardless of status (availability changes rarely). In `LMStudioClient`, add placeholders that compile: `fetchModels` → `[]`, `probeReachable` → `false`, `probeDetailed` → `.unreachable`, chat path → `throw ClientError.serverError("Apple Intelligence isn't wired up yet.")`.
- [ ] **Step 4: Run the full test suite.** Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit** — `feat(apple-intelligence): add ServerKind.appleIntelligence`.

### Task 2: `AppleIntelligenceRequest`, the pure mapping layer

**Files:**
- Create: `Modelo/Services/AppleIntelligenceRequest.swift` (no `import FoundationModels`)
- Test: `ModeloTests/AppleIntelligenceRequestTests.swift`

**Interfaces:**
- Consumes: `WireMessage` / `WireContent` (`ChatProvider.swift`), `LMStudioClient.wireMessages(_:systemPrompt:)`, `TokenEstimator.estimate(_: String)`, `SamplingParams`.
- Produces:

```swift
struct AppleIntelligenceRequest: Equatable {
    enum Turn: Equatable { case user(String), assistant(String) }
    static let contextTokens = 4096
    static let defaultResponseReserve = 1024
    static let trimNotice = "Earlier messages were dropped to fit Apple Intelligence's 4K context."

    var instructions: String?   // from the "system" wire message, if any
    var history: [Turn]          // oldest first, excludes the final prompt
    var prompt: String           // text of the final user message
    var droppedTurns: Int        // history turns removed to fit the budget

    /// nil when the last usable message isn't from the user.
    static func make(from wire: [WireMessage], responseReserve: Int) -> AppleIntelligenceRequest?
    /// Text to emit for a new cumulative snapshot; "" if `current` doesn't extend `previous`.
    static func delta(from previous: String, to current: String) -> String
    /// Temperature clamped to 0...1 (default 0.7); maxTokens passed through.
    static func generation(_ s: SamplingParams) -> (temperature: Double, maxTokens: Int?)
}
```

- [ ] **Step 1: Write failing tests:**
  - `test_make_mapsRoles`: system + user + assistant + user → `instructions`, `history == [.user(a), .assistant(b)]`, `prompt == last`, `droppedTurns == 0`.
  - `test_make_skipsToolTraffic`: a `"tool"` message and an assistant message with `content == nil` (tool-calls only) are absent from `history`.
  - `test_make_keepsTextBlocksDropsImages`: user `.blocks([.text("hi"), .imageURL("data:…")])` → `.user("hi")`; an image-only user turn is skipped.
  - `test_make_trimsOldestFirst`: history whose estimate exceeds `4096 - reserve` drops from the front; the instructions and the prompt survive; `droppedTurns` equals the number removed; the remaining estimate fits.
  - `test_make_neverTrimsInstructionsOrPrompt`: instructions + prompt alone over budget → returned unchanged, `history` empty.
  - `test_make_nilWhenLastIsNotUser`.
  - `test_delta`: `("", "Hel") == "Hel"`, `("Hel", "Hello") == "lo"`, `("Hello", "Help") == ""`.
  - `test_generation`: `temperature nil → 0.7`, `1.4 → 1.0`, `-0.2 → 0.0`, `maxTokens 200 → 200`.
- [ ] **Step 2: Run, expect failure** (type not defined).
- [ ] **Step 3: Implement.** Budget = `contextTokens - responseReserve`; cost = `TokenEstimator.estimate` over instructions + every turn + prompt. Drop `history.first` until it fits or `history` is empty. Add a `// ponytail:` note: the 4-chars-per-token heuristic can under-count, and Task 3's error mapping is the backstop.
- [ ] **Step 4: Run tests** — `-only-testing:ModeloTests/AppleIntelligenceRequestTests`, then the full suite. Expected: pass.
- [ ] **Step 5: Commit** — `feat(apple-intelligence): history mapping, trimming and delta diffing`.

### Task 3: `AppleIntelligenceClient` and the `.notice` stream event

**Files:**
- Create: `Modelo/Services/AppleIntelligenceClient.swift`
- Modify: `Modelo/Services/ChatProvider.swift` (`StreamEvent`)
- Modify: `Modelo/Services/LMStudioClient.swift` (replace Task 1's placeholders with forwarding)
- Modify: `Modelo/Services/ChatSession.swift:293` (switch), `Modelo/Services/Benchmark.swift:127` (switch)

**Interfaces:**
- Consumes: `AppleIntelligenceRequest` (Task 2).
- Produces:

```swift
// StreamEvent
case notice(String)   // non-fatal, user-visible note for this turn

enum AppleIntelligenceClient {
    static let modelID = "apple-on-device"
    /// One loaded, free, tool-less model when available; [] otherwise.
    static func models() -> [LMStudioModel]
    static func isAvailable() -> Bool
    /// True unless the device itself can't run Apple Intelligence (seeding uses this).
    static func isEligible() -> Bool
    /// nil when available; otherwise the user-facing reason (copy below).
    static func statusMessage() -> String?
    static func prewarm()
    static func streamChat(messages: [WireMessage], sampling: SamplingParams) -> AsyncThrowingStream<StreamEvent, Error>
}
```

Every function returns the unavailable answer (`[]`, `false`, the macOS 26 message, an immediate `ClientError.serverError`) when `#available(macOS 26, *)` fails, so callers need no checks.

- [ ] **Step 1: Write failing tests** in `ModeloTests/AppleIntelligenceRequestTests.swift`:
  - `test_models_shape`: `AppleIntelligenceClient.models()` is empty or exactly one model with `id == "apple-on-device"`, `isLoaded`, `isFree == true`, `toolUseSupported == false`, `maxContextLength == 4096`. (The real availability depends on the machine, so assert the shape, not the count.)
  - `test_statusMessage_nilIffAvailable`: `(statusMessage() == nil) == isAvailable()`.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** Availability copy, exact:
  - `.deviceNotEligible` → `"This Mac doesn't support Apple Intelligence."`
  - `.appleIntelligenceNotEnabled` → `"Turn on Apple Intelligence in System Settings."`
  - `.modelNotReady` → `"Apple Intelligence is still downloading its model."`
  - other → `"Apple Intelligence is unavailable right now."`
  - below macOS 26 → `"Requires macOS 26 or later."`

  `streamChat`: build the request with `make(from:responseReserve:)` (nil → throw `ClientError.serverError("Nothing to send.")`). If `droppedTurns > 0`, yield `.notice(AppleIntelligenceRequest.trimNotice)` first. Map to a `Transcript`: instructions → `.instructions(Transcript.Instructions(segments:toolDefinitions: []))`, `.user` → `.prompt(Transcript.Prompt(segments:))`, `.assistant` → `.response(Transcript.Response(assetIDs: [], segments:))`, with text in `.text(Transcript.TextSegment(content:))`. Then `LanguageModelSession(model: .default, tools: [], transcript:)` and `streamResponse(to: prompt, options: GenerationOptions(temperature:maximumResponseTokens:))`. Yield `.delta(AppleIntelligenceRequest.delta(from:to:))` per snapshot `.content`, skipping empty deltas. Run inside a `Task`, cancelled from `continuation.onTermination`, as `LMStudioClient.streamChat` does. Error copy: `GenerationError.exceededContextWindowSize` → `"This chat is too long for Apple Intelligence's 4K context. Start a new chat."`; `.guardrailViolation` / `.refusal` → `"Apple Intelligence declined to answer this."`; anything else → `localizedDescription`. All surface as `ClientError.serverError`.

  In `LMStudioClient`: `fetchModels` → `AppleIntelligenceClient.models()`; `probeReachable` → `isAvailable()`; `probeDetailed` → `.reachable` / `.unreachable`; at the top of `streamChat`, after `wireMessages`, return `AppleIntelligenceClient.streamChat(messages: wire, sampling: sampling)` for this kind. The chat-path switch case stays as an unreachable `throw`.

  `ChatSession` switch: `case .notice(let text): errorText = text` (reuses the banner; `errorText` is cleared at the start of each turn). `Benchmark` switch: `case .notice: break`. The `if case .delta` consumers ignore it unchanged. The menu-bar quick chat is one of them; see the merge note at the end.
- [ ] **Step 4: Run the full suite + build.** Expected: both succeed.
- [ ] **Step 5: Commit** — `feat(apple-intelligence): on-device chat via Foundation Models`.

### Task 4: Auto-add the server row once

**Files:**
- Modify: `Modelo/Services/ServerRegistry.swift` (next to `seedIfNeeded`, `:45`)
- Modify: `Modelo/ModeloApp.swift` (`init`, right after `registry.seedIfNeeded(in: ctx)`)
- Test: `ModeloTests/ServerRegistryTests.swift`

**Interfaces:**
- Produces: `func seedAppleIntelligenceIfNeeded(in context: ModelContext, isEligible: Bool, defaults: UserDefaults = .standard)`. Defaults key `"didSeedAppleIntelligence"`. Inserts `Server(label: "Apple Intelligence", host: "", port: 0, sortOrder: <max existing + 1>, kind: .appleIntelligence)`.

- [ ] **Step 1: Write failing tests** (in-memory context, and a throwaway `UserDefaults(suiteName: UUID().uuidString)!`):
  - `test_seedAppleIntelligence_insertsOnceWhenEligible`: two calls → exactly one `.appleIntelligence` row; flag set.
  - `test_seedAppleIntelligence_skipsWhenIneligible`: no row, flag **not** set (so a later eligible launch still seeds).
  - `test_seedAppleIntelligence_deletedRowStaysDeleted`: seed, delete the row, seed again → zero rows.
  - `test_seedAppleIntelligence_sortsLast`: with two existing servers, the new row's `sortOrder` is greater than both.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement**, and call it from `ModeloApp.init` with `isEligible: AppleIntelligenceClient.isEligible()`.
- [ ] **Step 4: Run the suite.** Expected: pass.
- [ ] **Step 5: Commit** — `feat(apple-intelligence): auto-add the provider once on eligible Macs`.

### Task 5: Settings row and prewarm

**Files:**
- Modify: `Modelo/Settings/SettingsView.swift` (`endpointRow(for:)` `:73`; new `private struct AppleIntelligenceSettingsRow` next to `CloudServerSettingsRow` `:1471`)
- Modify: `Modelo/ContentView.swift` (`launch(model:)`, `:381`)

**Interfaces:**
- Consumes: `AppleIntelligenceClient.statusMessage()`, `.prewarm()` (Task 3).

- [ ] **Step 1: Route the row.** In `endpointRow(for:)`, check `server.kind == .appleIntelligence` before the `isLocal` branch, so it never gets the host:port or GPU-agent form.
- [ ] **Step 2: Build `AppleIntelligenceSettingsRow(server:onDelete:)`.** It's `CloudServerSettingsRow`'s header (`:1488-1526`: `StatusLED`, label, `Chip`, the show/hide `PillToggle`, delete with the same confirmation dialog) with no chevron and no expand. Its subtitle reads `statusMessage() ?? "On-device · private · free"`.
- [ ] **Step 3: Prewarm.** In `launch(model:)`, add a branch: `else if model.server.kind == .appleIntelligence { AppleIntelligenceClient.prewarm() }`.
- [ ] **Step 4: Build.** Expected: `** BUILD SUCCEEDED **`. Run the suite.
- [ ] **Step 5: Commit** — `feat(apple-intelligence): settings row and prewarm on launch`.

### Task 6: Manual verification and the caching gate

No code. Install a worktree build (quit the installed Modelo first) on a Mac with Apple Intelligence on.

- [ ] **Step 1:** First launch: an "Apple Intelligence" row appears in Settings ▸ Endpoints with the "On-device · private · free" subtitle. `apple-on-device` is in the picker.
- [ ] **Step 2:** Chat in the main window and in the menu-bar quick chat. Replies stream in.
- [ ] **Step 3:** Press stop mid-reply: generation stops, partial text is kept (Review Focus 4).
- [ ] **Step 4:** Paste roughly 20K characters across a few turns: the trim notice appears in the banner and the chat keeps working.
- [ ] **Step 5:** Toggle the row off: the model leaves the picker. Delete the row and relaunch: it doesn't come back.
- [ ] **Step 6:** Turn Apple Intelligence off in System Settings: within about 60s the model leaves the picker and the row shows "Turn on Apple Intelligence in System Settings." (Review Focus 5).
- [ ] **Step 7: Caching gate.** Run Benchmark against `apple-on-device` with a ~3,500-token prompt (about 14,000 characters). Record TTFT p50/p95 under Decisions in the spec. p50 under ~1s → caching stays out. Over that, raise it before Tier 2.
- [ ] **Step 8: Commit** the spec update — `docs(spec): record Apple Intelligence TTFT gate result`.

## Merge note

`feature/menubar-improvements` moves the quick chat's `send()` into `QuickChatSession`. After both branches land, add `if case .notice(let t) = event { errorText = t }` there, so the quick chat shows the trim notice too. Until then it silently trims, which is harmless.
