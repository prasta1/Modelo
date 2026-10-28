# Design: Apple Intelligence (Foundation Models) as a provider

**Date:** 2026-10-28
**Status:** Scoped, decisions made (no code changes yet)
**Author:** Patrick + Claude

## Problem

Every provider Modelo supports needs something running or paid for: a local
server (LM Studio, llama.cpp, Ollama, oMLX, exo) or a cloud API key. On a Mac
with Apple Intelligence, Apple's ~3B on-device model is already installed, free,
private, and needs no setup — the Foundation Models framework (macOS 26+) exposes
it to apps. Modelo can't use it today.

## Goals

- Apple's on-device model appears in the model picker as a provider, with zero
  setup on eligible Macs, in both the main chat and the menu-bar quick chat.
- Keep the macOS 14 deployment target: everything gated behind
  `#available(macOS 26, *)`; older or ineligible Macs simply don't see it.
- Follow the existing per-`ServerKind` extension pattern (same as exo).
- No SwiftData migration.

## Non-goals (Tier 1)

- Tool calling, MCP, image input, structured (`@Generable`) output.
- Adapters / custom-trained models.
- Usage metrics beyond the existing token-estimate fallback.

## Background: how the codebase is shaped

- **One choke point.** Every caller — `ChatSession` (main chat),
  `MenuBarChatView`, `Benchmark`, `ServerMonitor`, the settings model list —
  goes through `LMStudioClient.shared`'s `fetchModels(endpoint:)` (`:50`),
  `probeReachable(endpoint:)` (`:127`) and `streamChat(...)` (`:301`), each of
  which already switches on `endpoint.kind`. Branching there to a new client
  covers every surface at once.
- **Precedent:** `ExoClient` is a dedicated peer client for a runtime whose
  shape differs from OpenAI-compatible HTTP (`docs/specs/2026-07-02-exo-runtime-support.md`).
- **`ServerKind` is exhaustive** (`Endpoint.swift:17`), so adding a case makes
  the compiler list every site that must handle it. Raw values persist in
  SwiftData; a new case is additive.
- **`ChatProvider` is stateless:** each call passes the full message history
  plus system prompt and `SamplingParams`, and yields `StreamEvent.delta`s.

## How Foundation Models differs (verified against the macOS 27 SDK, Xcode 27.0)

| Concern | Foundation Models | Consequence |
|---|---|---|
| Transport | In-process Swift API, no HTTP | New client, not a URL branch |
| Availability | `SystemLanguageModel.default.availability`: `.available` or `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` | Replaces reachability probing; each reason gets its own message |
| History | Stateful `LanguageModelSession`; rehydrate via `init(model:tools:transcript:)` + `Transcript(entries:)` (macOS 26) | Rebuild a transcript from Modelo's messages each turn |
| Streaming | `streamResponse(to:options:)` yields **cumulative snapshots**, not deltas | Diff consecutive snapshots into `.delta` events |
| Context | **4,096 tokens** total (instructions + all prompts + all outputs) on macOS 26; `contextSize` is queryable from macOS 27 | Must trim history; long chats will hit it |
| Sampling | `GenerationOptions(sampling:temperature:maximumResponseTokens:)`, temperature 0…1 | Map `temperature` (clamped) + `maxTokens`; drop `topP`, penalties, `stop` |
| Errors | `GenerationError.exceededContextWindowSize`, guardrail violations (macOS 26); `LanguageModelError.contextSizeExceeded` (macOS 27) | Map to `ClientError.serverError` with readable text |
| Tools | Framework **executes tools itself** inside the session | Doesn't fit Modelo's loop (app receives `.toolCalls`, runs them, re-sends) — Tier 2 |
| Images | `Transcript.Attachment.image` — **macOS 27 only** | Tier 3 |

## Design

### Tier 1 — on-device text chat (macOS 26+)

New `ServerKind.appleIntelligence` (raw value `"appleIntelligence"`), with a
fixed "URL" (no host, port or key), plus a dedicated `AppleIntelligenceClient`
in `Modelo/Services/`, all of it `@available(macOS 26, *)`.

**Touchpoints:**

1. **`Endpoint.swift`:** new case. `displayName` "Apple Intelligence",
   `defaultPort` 0, `hasFixedURL` true. `isLocal`: see open decision 2.
2. **`Server.swift`:** `baseURL` gets a sentinel (e.g. `"apple-intelligence://on-device"`)
   so `Endpoint` stays non-optional.
3. **`AppleIntelligenceClient.swift`** (new, ~120 lines):
   - `fetchModels` returns one `LMStudioModel` (`id: "apple-on-device"`,
     marked loaded) when available, `[]` otherwise.
   - `probeReachable` returns `availability == .available`.
   - `streamChat`: messages → `Transcript` (system prompt → `.instructions`,
     history → `.prompt` / `.response`, last user message → the prompt). Trim
     oldest turns until it fits (character heuristic via the existing
     `TokenEstimator`). Diff snapshots → `.delta`. Ignore `tools`.
4. **`LMStudioClient.swift`:** `case .appleIntelligence` in `fetchModels`,
   `probeReachable`, `streamChat` → forward to `AppleIntelligenceClient`
   (each behind `#available`, falling back to `[]` / `false` / `.unsupported`).
5. **`ReachabilityMonitor.swift`:** poll interval; availability changes rarely
   (model download, Apple Intelligence toggled), so a slow interval.
6. **Settings / `ServerRow` / `ServerStatsView` / `LauncherView`:** icon
   (`apple.intelligence` SF Symbol), no host/port/key fields, and a status line
   explaining *why* when unavailable ("Turn on Apple Intelligence in System
   Settings", "Model still downloading", "This Mac isn't eligible").
7. **`ServerRegistry`:** on launch, on an eligible Mac, insert one
   "Apple Intelligence" server row if this hasn't been done before (a
   `UserDefaults` flag, so a deleted row stays deleted). The user hides it from
   the picker with the existing per-server show/hide toggle (`isPaused`,
   `SettingsView.swift:989`), which also stops its background polling. No new
   setting.
8. **Context overflow notice:** when trimming drops turns, surface a one-line
   notice in the chat ("Earlier messages were dropped to fit Apple
   Intelligence's context window"). Exact surface is decided in the plan (an
   inline system note or the existing error banner).

The compiler will add any `switch` sites missed above.

**Result:** on an eligible Mac, "Apple Intelligence" appears in the picker and
chats work everywhere, including the menu-bar quick chat, with no setup.

### Tier 2 — tool calling (follow-on)

Bridge Modelo's `ToolSpec`s (JSON Schema) to Foundation Models `Tool`s using
`DynamicGenerationSchema` / `GeneratedContent`. The hard part is the loop
mismatch: the framework invokes `Tool.call` itself, so the bridge has to either
run Modelo's tool executor from inside `call` (bypassing `ChatSession`'s
approval UI and persisted tool-call messages) or suspend and surface a
`.toolCalls` event. Needs its own spec. The 4K context also limits how many
tool definitions fit.

### Tier 3 — macOS 27 features (follow-on)

Image input (`Transcript.ImageAttachment`), exact context budgeting via
`contextSize`, and the newer `LanguageModelError` cases. **Blocker:** CI's
`release.yml` runs on `macos-26`; macOS 27 symbols don't compile there, even
behind `#available`. Bump the runner first.

## Testing

- **Unit:** messages → transcript mapping (roles, system prompt, trimming
  oldest-first under budget); snapshot → delta diffing; sampling mapping
  (temperature clamp, dropped params). Pure functions, no model needed.
- **Unit:** `ServerKind.appleIntelligence` properties; `baseURL` sentinel.
- **Not unit-tested:** real generation. CI runners don't have Apple
  Intelligence enabled. Manual check on this Mac: chat, stop mid-stream,
  overflow a long chat, toggle Apple Intelligence off and back on.

## Migration & safety

- Additive enum case; no schema change. An older build reading a DB that
  contains an `appleIntelligence` row won't crash: `Server.kind` falls back to
  `.lmStudio` for unknown raw values (`Server.swift:51`). It will show that row
  as a dead LM Studio server, which is acceptable on a downgrade.
- Private by construction: nothing leaves the Mac. No keys.

## Decisions (2026-10-28)

1. **How it appears:** auto-added once on eligible Macs. Hidden from the picker
   via the existing per-server show/hide toggle; a deleted row stays deleted.
2. **`isLocal`:** `true` (free, private, never "NOT LOADED"). The host:port
   fields and `modelo-tap` GPU-agent sites exclude it explicitly.
3. **Context overflow:** trim the oldest turns and show a one-line notice.

## Open (resolve in the plan)

- **Session caching:** Tier 1 rebuilds the session each turn, so the model
  re-reads the transcript with no KV cache. At ≤4K tokens on-device this should
  be fast. Measure before adding a per-conversation session cache.
