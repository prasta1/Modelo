# Modelo ⨉ Fornax — Merge & Joint-Project Plan

> Goal: fold Fornax's capabilities into **Modelo** (native macOS, Swift/SwiftUI/SwiftData)
> and run it as a joint project. This document specs each feature against Modelo's
> *actual* code — files, types, line ranges — so either of us can pick up any item.

Status legend: 🟢 low effort · 🟡 medium · 🔴 high/uncertain
Each item lists: **Goal · Modelo touchpoints · Schema · Steps · Effort · Fornax reference.**

---

## Progress

Completed item status: ✅ done · 🔶 in progress / in review · ⬜ not started.

- ✅ **Phase 0 groundwork** — `MERGE_PLAN.md` / `AGENTS.md` / `CLAUDE.md` added; `upstream`
  remote (`prasta1/Modelo`) wired; collaboration model agreed (PR #2 fork / PR #8 upstream).
- 🔶 **`modelo-tap` agent vendored + renamed** (ex `fornax-agent`) — builds, runs (PR #3).
- ✅ **Local server runtimes** — `ServerKind.llamaSwap` added (LM Studio + llama.cpp/llama-swap
  are local; cloud stays cloud). Groundwork for §2.1 gating and §2.3 (PR #4). vLLM/sglang
  are future enum cases.
- 🔶 **§2.1 Remote GPU telemetry via `modelo-tap`** — agent (PR #3) + Swift consumer
  (`Server.metricsAgentURL`, `GPUMonitor`, `GPUSnapshot`, Status tiles, Settings Agent URL)
  (PR #4). Builds green, 25 tests pass; pending merge + live verification on an NVIDIA box.
- 🔶 **§1.1 Markdown rendering + code highlighting** — `MarkdownText` (MarkdownUI 2.4.1),
  Highlightr-backed code blocks with per-block copy, streaming gate in `MessageRow`/`ChatView`
  (PR #5). First third-party deps. Builds green, 70 tests pass; pending merge.
- 🔶 **§1.2 Conversation branching tree** — `Message` parent/children/`branchIndex`;
  `Conversation.activeLeafData` (encoded `PersistentIdentifier`) + `activePath`/`appendToPath`/
  `branch`/`dropLeaf`; `BranchingMigration` launch backfill; `send` rewritten onto the active
  path; `◀ k/n ▶` sibling nav + edit-as-branch (PR #6, stacked on #5). Builds green, 78 tests
  pass; pending merge + on-device migration verification. Root branching deferred.
- 🔶 **§1.3 Regenerate assistant response** — shared `runTurn` extracted from `send`; new
  `ChatSession.regenerate` forks an assistant sibling under the same user parent and streams
  into it; "Regenerate" footer action + `◀ k/n ▶` now lights up on assistant turns (PR #7,
  stacked on #6). Builds green, 79 tests pass; pending merge.
- ⬜ Everything else below.

> Sequencing note: §2.1's Swift side required a local-vs-cloud distinction, so the
> llama.cpp/llama-swap runtime (originally implied by §2.2–2.3) was pulled forward.

---

## 0. Strategic decision: port, don't fuse codebases

Modelo and Fornax are the **same product built on different stacks** (Swift/SwiftData vs.
Rust/Tauri/React). We are **not** merging source trees — we keep Modelo's native Swift
codebase as the base of truth and **reimplement** Fornax features in Swift. Two exceptions
are reused *as artifacts*, not ported:

- **`modelo-tap`** (renamed from `fornax-agent`) — a standalone Rust HTTP/JSON binary.
  Stack-agnostic; vendor it, rename the crate/binary, keep the `GET /gpu` + `/health` wire
  contract unchanged. ("tap" = a beer tap *and* a network/metrics tap.)
- **Fornax's `ios/FornaxMobile`** — already SwiftUI; becomes a Modelo iOS target
  (**ModeloMobile**) that *shares the SwiftData models*. Rebrand fully to Modelo: app name,
  bundle id, icon/assets, accent colors, and any "Fornax" strings. Biggest cross-project synergy.

Things Modelo already does **better** than Fornax — do not regress these:
- **Keychain** secret storage (Fornax keeps API keys in plaintext `config.toml`).
- **OpenRouter catalog** with authoritative pricing / vision / tool-use metadata.
- **Personas**, **folders**, **menu-bar mini chat**, **LM Studio load/unload**.

### Repo / collaboration model (proposed)

```
Modelo/                      # this repo becomes a small monorepo
├─ Modelo/                   # macOS app (existing)
├─ ModeloMobile/             # iOS target, seeded from fornax/ios/FornaxMobile
├─ ModeloKit/                # NEW shared Swift package: models + services
│                            #   (Conversation, Message, ChatSession, clients…)
├─ modelo-tap/               # vendored GPU-metrics agent (Rust, ex-fornax-agent)
├─ MERGE_PLAN.md             # this file
└─ Modelo2.xcodeproj         # XcodeGen output from project.yml
```

- Extracting `ModeloKit` (models + services) as a local Swift package lets macOS and iOS
  share `Conversation`/`Message`/`ChatSession`/`LMStudioClient`. Do this **early** (it makes
  the iOS target cheap) but it can be deferred until after the Tier-1 chat features land.
- Two-dev hygiene: protect `main`, PR review for each item, one feature branch per section
  below, `CONTRIBUTING.md` + a shared license. Keep `project.yml` (XcodeGen) the source of
  truth for targets so the `.xcodeproj` never causes merge conflicts.

---

## Phase 1 — Core chat parity (do first; touches the message model)

Order matters: the **branching schema change (1.2)** reshapes `Message`, and 1.1/1.3 build on
it. Land these before the data model ossifies further.

### 1.1 Markdown rendering + code syntax highlighting 🟡 — 🔶 IN REVIEW (PR #5)

> Status: `Modelo/Views/MarkdownText.swift` wraps `Markdown(content)` in a Modelo-themed
> `MarkdownUI.Theme` (amber inline-code/links, `Theme.textMid` body); fenced blocks render on
> `Theme.consoleBG` with a language label + per-block copy, syntax-highlighted via a shared
> Highlightr (`atom-one-dark`). `MessageRow` swaps `Text`→`MarkdownText` gated by an
> `isLiveStreaming` flag set in `ChatView` (plain text while streaming, Markdown on completion).
> User bubbles stay plain for now. First third-party deps (MarkdownUI 2.4.1, Highlightr 2.3.0).
> Builds green; 70 tests pass. Remaining: merge.

**Goal.** Replace plain-text message bodies with Markdown (GFM) + syntax-highlighted code blocks.
This is Modelo's single most visible gap — today everything is `Text(message.content)`.

**Modelo touchpoints.**
- `Modelo/Views/MessageRow.swift` — assistant content (lines ~77–123) and user bubble (~46–62)
  currently render plain `Text(message.content)` with `.textSelection(.enabled)`.
- `Modelo/Theme.swift` — already has `Theme.code(size)` (monospaced) and `Theme.mono(...)`;
  use these for code blocks so styling matches.
- `Modelo/Views/MenuBarChatView.swift` `QuickMessageRow` (~303–339) — optional, later.

**Schema.** None.

**Steps.**
1. Add a dependency. Recommended: **swift-markdown-ui** (`MarkdownUI`) via SPM — supports GFM
   tables/task-lists, custom theming, and pluggable code-block rendering. Add to `project.yml`
   `packages:`/`dependencies:`. (Modelo currently has zero third-party deps — this is a
   deliberate first exception; the alternative is `AttributedString(markdown:)` which can't do
   fenced code blocks or tables well.)
2. Code highlighting: render fenced blocks with **Splash** (pure-Swift, Swift-focused) or
   **Highlightr** (highlight.js, 180+ languages). Recommend Highlightr for language breadth to
   match Fornax's shiki coverage; wire it as MarkdownUI's `CodeSyntaxHighlighter`.
3. Create `Modelo/Views/MarkdownText.swift` wrapping `Markdown(content)` with a `Theme`-derived
   `MarkdownUI.Theme` (body color `Theme.textMid`, code via `Theme.code`, link `Theme.amber`).
4. Swap `Text(message.content)` → `MarkdownText(message.content)` in `MessageRow` assistant body.
   Keep user bubbles plain (or render markdown too — cheap once the view exists).
5. **Streaming cost:** re-parsing markdown on every 50ms delta flush is expensive. Render
   **plain `Text` while `session.isStreaming` for the active message**, swap to `MarkdownText`
   on completion. `ChatSession.isStreaming` (already `private(set)`) gates this.
6. Add a per-code-block **copy button** (matches Fornax) — MarkdownUI exposes the raw code in
   its code-block view builder.

**Effort.** 🟡 (dependency choice + streaming throttle are the only subtleties).
**Fornax ref.** `src/components/MessageItem.tsx`, react-markdown + remark-gfm + shiki; `src/lib/segments.ts`.

---

### 1.2 Conversation branching tree 🔴 — 🔶 IN REVIEW (PR #6, stacked on #5)

> Status: `Message` gained a `parent`/`children` self-relationship + `branchIndex` (with
> `siblings`/`siblingIndex`/`subtreeLeaf` helpers); `Conversation` tracks the active leaf as an
> encoded `PersistentIdentifier` (`activeLeafData`) — chosen over a new `Message.id` to avoid the
> UUID-default footgun and an extra inverse — plus `activePath`/`appendToPath`/`branch`/`dropLeaf`.
> `ChatSession.send` builds the wire from `activePath().filter(wireKeep)`, links new turns via
> `appendToPath`, forks via a `replacing:` param, and re-encodes the leaf once ids are permanent.
> `MessageRow` shows `◀ k/n ▶`; editing a user turn forks a sibling. `BranchingMigration` chains
> legacy flat conversations at launch (idempotent, flag-guarded). Builds green; 78 tests pass.
> Deferred: **root-turn branching** (editing the first turn resends linearly) and **assistant
> regenerate** (§1.3, will reuse `branch`). Remaining: merge + on-device migration verification.

**Modelo touchpoints.**
- `Modelo/Models/Message.swift` — add tree fields.
- `Modelo/Models/Conversation.swift` — add active-leaf pointer.
- `Modelo/Services/ChatSession.swift` — `send(...)` (lines ~34–189) currently appends linearly
  and builds the wire array from *all* messages sorted by `createdAt` (`wireKeep`, ~260–264).
  This must change to **walk the active path** from root → active leaf.
- `Modelo/Views/MessageRow.swift` — add sibling-nav control + regenerate/edit actions.
- `Modelo/Views/ChatView.swift` — message list (~108–142) must render the active path, not
  `conversation.messages` raw.

**Schema (SwiftData lightweight migration — additive optionals are automatic).**
```swift
// Message.swift
@Relationship(deleteRule: .nullify) var parent: Message?      // self-ref
@Relationship(deleteRule: .cascade, inverse: \Message.parent)
    var children: [Message] = []
var branchIndex: Int = 0     // position among siblings under the same parent

// Conversation.swift
var activeLeafID: UUID?       // tail of the currently-selected path
// (Message has no stable unique `id` today — add `var id: UUID = UUID()` to Message,
//  OR store activeLeaf as PersistentIdentifier-encoded string like the route persistence does.)
```
> Note: existing rows have no parent links. Write a **one-time migration** on launch that
> chains each conversation's messages by `createdAt` (m[n].parent = m[n-1]) and sets
> `activeLeafID` to the last message. Idempotent: skip conversations whose messages already
> have parents.

**Steps.**
1. Add fields + migration pass (run once in `ModeloApp` after `ModelContainer` init, guarded by
   a `@AppStorage("didMigrateBranching")` flag).
2. Add path helpers (mirror Fornax `conversation_storage.rs` `walk_from`/`siblings_of`):
   `Conversation.activePath() -> [Message]`, `Message.siblings -> [Message]`.
3. Rewrite `ChatSession.send` to build the wire array from `activePath()` instead of
   `messages.sorted(by: createdAt)`. New assistant/tool messages get `parent = ` last path node.
4. **Regenerate** (see 1.3) and **edit user turn**: create a *new child* under the same parent
   with `branchIndex = max(siblings)+1`, set `activeLeafID`, re-stream.
5. `MessageRow`: when a message has >1 sibling, show `◀ k/n ▶`; tapping switches `activeLeafID`
   to that sibling's subtree leaf and refreshes the list.

**Effort.** 🔴 (schema + migration + send-path rewrite + UI). The keystone item.
**Fornax ref.** `messages` table `parent_id`/`branch_index`/`position`; `commands.rs` `message_siblings`, `walk_from`.

---

### 1.3 Regenerate assistant response 🟢 (after 1.2) — 🔶 IN REVIEW (PR #7, stacked on #6)

> Status: the agentic streaming loop was extracted from `send` into a shared `runTurn(...)`;
> `ChatSession.regenerate(_:in:server:…)` pre-branches an empty assistant sibling (via §1.2's
> `branch`) and streams into it, so the wire re-walks the same user prompt. A "Regenerate"
> action sits in the assistant footer and the `◀ k/n ▶` control now lights up on assistant
> turns. Title generation is gated to first-exchange sends. Builds green; 79 tests pass.

**Goal.** Re-run the last (or any) assistant turn. Modelo today only supports "edit & resend"
on *user* turns (`MessageRow` ~167–204).

**Modelo touchpoints.** `MessageRow.swift` assistant footer (~141–163); `ChatSession.swift`.

**Steps.**
1. Add a "regenerate" button to the assistant hover/footer actions next to copy/share.
2. With branching (1.2): create a new sibling assistant message under the same user parent,
   set it active, call a new `ChatSession.regenerate(from:)` that streams into it.
3. Without branching (fallback if 1.2 slips): delete messages after the target user turn and
   re-`send` — simpler but lossy. Prefer the branching path.

**Effort.** 🟢 once 1.2 exists.
**Fornax ref.** regenerate = new sibling branch; `MessageItem.tsx` nav controls.

---

### 1.4 Full sampling controls + presets 🟡

**Goal.** Expose top_p, max_tokens, frequency/presence penalty, stop sequences (Modelo sends
**temperature only** today). Bundle as reusable **presets**.

**Modelo touchpoints.**
- `Modelo/Services/ChatProvider.swift` — `streamChat(...)` signature currently takes
  `temperature: Double` only.
- `Modelo/Services/LMStudioClient.swift` — `ChatRequest` struct (~199–209) only encodes
  `temperature`, `stream`, `stream_options`.
- `Modelo/Services/ChatSession.swift` — `send` passes `temperature` (line ~86).
- `Modelo/Models/Conversation.swift` — has `temperature: Double?` only.
- `Modelo/Settings/SettingsView.swift` — add a sampling section / per-conversation editor.

**Schema.**
```swift
// Conversation.swift — all optional (nil = inherit global default)
var topP: Double?
var maxTokens: Int?
var frequencyPenalty: Double?
var presencePenalty: Double?
var stopSequences: [String]?     // SwiftData stores [String] fine
// NEW @Model Preset { name, model?, systemPrompt?, temperature?, topP?, maxTokens?,
//                      frequencyPenalty?, presencePenalty?, stopSequences?, sortOrder }
//   register in ModeloApp Schema([...])
```

**Steps.**
1. **Refactor to a value type** to avoid signature churn: introduce
   `struct SamplingParams: Sendable { temperature, topP, maxTokens, frequencyPenalty,
   presencePenalty, stop }`. Change `ChatProvider.streamChat(..., sampling: SamplingParams)`.
   Update `LMStudioClient.ChatRequest` to encode the non-nil fields (omit nils so servers that
   reject unknown params stay happy). Update the test mock conforming to `ChatProvider`.
2. Resolve effective params in `ChatSession.send`: conversation override → global default.
3. Add `Preset` model + CRUD UI (reuse `PersonaSettingsRow` collapsible pattern). "Apply
   preset" writes fields onto the conversation; "Save preset" captures current ones.
4. Global defaults live in `@AppStorage` or a settings model.

**Effort.** 🟡 (protocol change ripples to client + tests).
**Fornax ref.** `preset_storage.rs`; per-conversation `settings` JSON; `SettingsModal.tsx`.

---

### 1.5 Auto-compaction of long conversations 🟡

**Goal.** When history nears the model's context window, summarize the oldest messages into a
compaction summary so chats can run indefinitely. Modelo already tracks
`Conversation.contextTokensUsed` and `LMStudioModel.maxContextLength`.

**Modelo touchpoints.** `ChatSession.send` (build-messages step, ~69–86); `Conversation.swift`;
`LMStudioModel.maxContextLength` for the window.

**Schema.**
```swift
// Conversation.swift
var summary: String?              // compaction summary text
var summaryThroughID: UUID?       // last message folded into the summary
var autoCompact: Bool = false
var compactThresholdPct: Double?  // 0.3–0.95, default 0.85
var compactKeepRecent: Int?       // default 8 messages kept verbatim
var compactPrompt: String?        // custom summarization template
```

**Steps.**
1. Before building the wire array, estimate active-path tokens (reuse 1.6's estimator). If
   `tokens > threshold * contextWindow` and `contextWindow` is known (`maxContextLength`):
2. Take messages older than `compactKeepRecent`, send them to the model with `compactPrompt`
   (a separate non-streaming call via `LMStudioClient`), store result in `summary` /
   `summaryThroughID`.
3. Wire array becomes: `[system] + [summary as system/assistant note] + recent messages`.
4. Settings UI: master toggle + threshold slider + keep-recent stepper (global + per-convo).

**Effort.** 🟡 (needs a token estimate + an extra model call).
**Fornax ref.** `conversation_storage.rs` summary/`summary_through`; `compact_*` config keys.

---

### 1.6 Live token counting + context bar 🟡

**Goal.** Live token estimate in the composer as you type, plus a context-usage bar that fills
and turns amber at 80%. Modelo shows post-hoc `tokenCount` per message but nothing live.

**Modelo touchpoints.** `ChatView.swift` composer (~218–272); there's already a `ContextBar`
helper view and `Conversation.contextTokensUsed`.

**Schema.** None.

**Steps.**
1. Add a token estimator service. Honest options:
   - **v1 (now):** heuristic `~chars/4` (and per-message caching). Cheap, no deps.
   - **v2 (later):** a real BPE tokenizer. No first-class Swift `gpt-tokenizer` equivalent;
     candidates are bundling a tokenizer via `swift-transformers` (Hugging Face) or shelling a
     small helper. Treat as a follow-up; the heuristic is fine for a usage bar.
2. Compute draft tokens on `draft` change (debounced) + sum active-path tokens for context use.
3. Render count near the send button; drive `ContextBar` fill from
   `contextTokensUsed / contextWindow`, amber ≥ 0.8 (use `Theme.amber`).

**Effort.** 🟡 (🟢 if shipping the heuristic only).
**Fornax ref.** `src/lib/tokens.ts` (gpt-tokenizer); composer count + context bar in `ChatView.tsx`.

---

## Phase 2 — Instrument-panel differentiators (play to Modelo's identity)

### 2.1 Remote GPU telemetry via `modelo-tap` 🟢🟡 — recommended early win — 🔶 DONE (PR #3 + #4, pending merge)

> Status: agent vendored/renamed (PR #3); Swift consumer — `Server.metricsAgentURL`,
> `GPUMonitor`, `GPUSnapshot`, Status card tiles, Settings "Agent URL" field — landed in PR #4
> alongside the `ServerKind.llamaSwap` local-server kind. Builds green; 25 tests pass.
> Remaining: Console-inspector GPU charts (deferred), and live verification on an NVIDIA box.

**Goal.** Show live VRAM / power / temp / GPU-util from a remote inference box (DGX Spark,
vLLM host) on the Status dashboard + Console inspector. The agent is **reused as-is** (only
renamed) — only Modelo-side polling + tiles are new.

**Modelo touchpoints.**
- `Modelo/Models/Server.swift` — add `metricsAgentURL: String?`.
- New `Modelo/Services/GPUMonitor.swift` — model on `ReachabilityMonitor.swift` /
  `ServerMonitor.swift` (per-server `Task` polling loops, `@Observable @MainActor`).
- `Modelo/Views/StatusView.swift` — 2×2 metric grid (~105–114) gains VRAM/power/temp tiles;
  add a per-GPU rows section.
- `Modelo/Views/ConsoleInspector.swift` — add `MetricStat` blocks (~82–91 pattern) + a
  `GPUUtilChart`/`GPUPowerChart` mirroring `ThroughputChart`.
- `Modelo/Settings/SettingsView.swift` — add an "Agent URL" field to `ServerSettingsRow`.

**Schema.** `Server.metricsAgentURL: String?` (additive, automatic migration).

**Wire format (from `modelo-tap` `GET /gpu`, ex-`fornax/agent/src/main.rs`):**
```swift
struct GPUSnapshot: Codable, Equatable, Sendable {
    var vram_used_gb, vram_total_gb, power_w, power_limit_w, temp_c, util_pct: Double
    var devices: [Device]
    struct Device: Codable, Equatable, Sendable {
        var name: String
        var util_pct, mem_used_gb, mem_total_gb, temp_c, power_w, power_limit_w: Double
    }
}
```

**Steps.**
1. Add `metricsAgentURL` + Settings field.
2. `GPUMonitor`: for each server with an agent URL, poll `GET {url}/gpu` ~1.5s via `URLSession`,
   decode `GPUSnapshot`, store `[UUID: GPUSnapshot]` + a short ring buffer for charts. Follow
   `ServerMonitor`'s loop/cancel pattern; respect online state from `ServerRegistry`.
3. Wire into `StatusView` tiles + `ConsoleInspector` charts (new accent: `Theme.blue`).
4. Vendor + rename the agent: copy `fornax/agent/` → `modelo-tap/`, rename the crate/binary in
   `Cargo.toml` (`fornax-agent` → `modelo-tap`), update the binary name in `--help`/log strings
   and the systemd unit in its README. **Do not change the `GET /gpu` / `/health` wire contract**
   — the `GPUSnapshot` decoder above depends on it.

**Effort.** 🟢 client + 🟡 charts. High value when inference runs off-box.
**Fornax ref.** `src-tauri/src/metrics/gpu.rs` (agent polling); `agent/src/main.rs`; `StatusView.tsx`.

---

### 2.2 Local Apple-Silicon GPU stats (macmon) 🔴

**Goal.** VRAM/power/temp/util for the *local* Mac, no sudo. Fornax uses the `macmon` Rust crate.

**Modelo touchpoints.** Same surfaces as 2.1 (`GPUMonitor`, Status, Console).

**Steps.** No native Swift macmon equivalent. Pragmatic path: **bundle the `macmon` binary**
and parse its JSON pipe output from `GPUMonitor` (same `GPUSnapshot` shape), or call IOReport
private APIs (more work, brittle). Recommend the binary-shell approach; gate behind a
`gpuSource` enum on `Server` (`none | agent | macmon`) matching Fornax's config.

**Effort.** 🔴 (sandbox/entitlements for shelling a bundled binary; uncertainty).
**Fornax ref.** `metrics/gpu.rs` macmon path; `gpu = "macmon"` config.

---

### 2.3 Prometheus scrape (vLLM / llama.cpp / llama-swap) 🟡

**Goal.** Server-wide throughput, TTFT p50/p95, KV-cache %, in-flight requests from a backend's
`/metrics`. Complements per-request client metrics Modelo already computes.

**Modelo touchpoints.** `Server.swift` add `prometheusURL: String?`; extend `GPUMonitor` (or a
sibling `PrometheusMonitor`) to scrape + parse the text exposition format; surface in Status.

**Effort.** 🟡 (text-format parser for a handful of metric names).
**Fornax ref.** `metrics/prometheus.rs`.

---

### 2.4 Artifacts panel (HTML / SVG / Markdown / Mermaid) 🔴

**Goal.** A right-side dock that live-previews artifacts parsed from assistant code fences, with
preview/source toggle. No Modelo equivalent.

**Modelo touchpoints.**
- New `Modelo/Services/ArtifactParser.swift` — extract fenced blocks, classify
  `html|svg|markdown|mermaid|code`, derive titles (mirror Fornax `lib/artifacts.ts`).
- New `Modelo/Views/ArtifactPanel.swift` — an inspector like `ConsoleInspector`
  (`.inspectorColumnWidth`), with a carousel/dropdown for multiple artifacts.
- HTML/SVG/Mermaid render in a `WKWebView` via `NSViewRepresentable`; bundle `mermaid.min.js`
  locally; sandbox the HTML iframe (`allow-scripts allow-forms`, no network).
- `ContentView.swift` / `ModeloApp.swift` — add a toggle + shortcut (mirror ⌘I console inspector;
  e.g. ⌘J like Fornax), and an `@AppStorage("artifactPanelOpen")`.

**Schema.** None (artifacts are derived from message content at render time).

**Effort.** 🔴 (WebView plumbing + Mermaid bundling + auto-open-on-completion logic).
**Fornax ref.** `components/ArtifactPanel.tsx`, `lib/artifacts.ts`.

---

### 2.5 Benchmark / load-test mode 🟡

**Goal.** Fire N requests at chosen concurrency against an endpoint; report TTFT p50/p95,
decode tok/s p50/p95, success/error, wall time, per-request series + charts.

**Modelo touchpoints.** New `Modelo/Services/BenchmarkRunner.swift` (reuses
`LMStudioClient.streamChat` + the `Endpoint`); a "Benchmark" mode on `StatusView` (Live |
Benchmark toggle like Fornax) reusing the existing Swift Charts patterns
(`ThroughputChart`/`TTFTChart`).

**Effort.** 🟡.
**Fornax ref.** `commands.rs` `run_bench`; `StatusView.tsx` benchmark UI.

---

## Phase 3 — Quality-of-life & polish

### 3.1 Slash commands in chat 🟢🟡
`/model /temp /system /clear /copy /help` (+ aliases). Parse `draft` in `ChatView.send` before
dispatch; new `Modelo/Services/SlashParser.swift`. Maps to existing conversation fields +
clipboard. **Touchpoint:** `ChatView.swift` ~218–272. **Fornax ref.** `src/lib/slash.ts`, `core/slash.rs`.

### 3.2 Markdown export + `/copy` 🟢
`Modelo/Services/ConversationExporter.swift` → Markdown (`## User` / `## Assistant`, timestamps,
optional reasoning strip) to a save panel / `~/Downloads`. **Fornax ref.** `conversation_storage.rs`
markdown export.

### 3.3 Queue-while-streaming 🟢🟡
Let the user type + queue messages during a stream; auto-send on completion.
`ChatSession.isStreaming` already exists; add a pending-queue in `ChatView`/`ChatSession`.
**Fornax ref.** auto-continue/steering in `ChatView.tsx`.

### 3.4 Configurable usage retention 🟢
Prune `UsageRecord` older than `usageRetentionDays` on launch + when Reports opens
(`UsageRecorder`/`ReportCalculator`). Add a settings field (0 = forever). Modelo keeps usage
forever today.

### 3.5 Themes beyond dark 🟡🔴
`Theme.swift` is **static** and the app forces `.preferredColorScheme(.dark)`. Real theming
means making tokens dynamic (environment-injected `Theme` value, or `@AppStorage` palette
selection) and auditing all `Theme.*` call sites. Add Light + Catppuccin flavors + font/size/
scale settings. **Effort scales with how many hardcoded colors exist** — token call sites are
already centralized in `Theme.swift`, which helps. **Fornax ref.** 6 themes in `config.toml`.

### 3.6 MCP streamable-HTTP transport 🟡
`Modelo/Services/MCPClient.swift` is a stdio `actor`. Add an HTTP transport variant + a
`transport` field on `MCPServerConfig`. **Fornax ref.** `rmcp` stdio + streamable-HTTP.

### 3.7 Portable `~/.agents` convention 🟡
Discover `commands/`, `skills/`, `tools/` from `~/.agents`, `~/.agents/local`, and the
conversation working dir; expose slash commands + a `use_skill` tool. New
`Modelo/Services/AgentsLoader.swift`; integrates with `ToolRegistry` + 3.1. **Fornax ref.**
`core/agents.rs`. (Interops with Claude Code etc.)

---

## Phase 4 — iOS companion (high synergy)

### 4.1 ModeloMobile target 🔴 (but mostly assembly, not invention)
Fornax already ships a SwiftUI iOS app (`fornax/ios/FornaxMobile`, ~9 files: `ConversationStore`,
`LLMClient`, settings, streaming chat with tok/s + TTFT). Strategy:
1. Extract `ModeloKit` (Phase 0) so models + `ChatSession` + `LMStudioClient` are shared.
2. Seed `ModeloMobile/` from FornaxMobile, then **rewire its client/store onto ModeloKit** so
   macOS and iOS share one chat engine and (optionally, later) sync.
3. **Rebrand fully to Modelo:** app display name, bundle identifier, app icon + asset catalog,
   accent palette (lime/amber to match the macOS theme), launch screen, and every "Fornax"
   string in code/Info.plist. Treat this as a checklist item in the seeding PR.
4. Keep iOS feature set lean initially (chat + streaming metrics), matching Fornax's iOS scope.

**Effort.** 🔴 overall, but the shared-engine approach avoids reinventing chat on iOS.
**Fornax ref.** `ios/FornaxMobile/` (`ConversationStore.swift`, `LLMClient.swift`).

---

## Suggested sequencing

1. **Phase 1.1 → 1.2 → 1.3** (markdown, then branching + regenerate) — biggest UX wins, and
   1.2 must precede further `Message` changes.
2. **2.1 fornax-agent** in parallel — cheap, independent, on-brand, no schema risk.
3. **1.4 sampling/presets → 1.5 compaction → 1.6 token bar** — these share the token estimator.
4. **2.4 artifacts** and **2.5 benchmark** — the standout differentiators.
5. **Phase 3** polish opportunistically; **Phase 0 `ModeloKit`** before **Phase 4 iOS**.

## Cross-cutting design rules (keep the native feel)
- All color via `Theme.*`; panels via `.panel(...)`; inputs via `.fieldChrome(focused:)`.
- New polling services follow `ReachabilityMonitor`/`ServerMonitor` (`@Observable @MainActor`,
  per-id `Task` loops, cancel on stop, respect `ServerRegistry` online state).
- New settings sections follow `ServerSettingsRow`/`PersonaSettingsRow` patterns.
- Schema additions: prefer **optional** properties (SwiftData migrates automatically); write an
  idempotent launch-time backfill only when existing rows need derived values (1.2).
- Keep secrets in **Keychain** (`KeychainStore`), never in plaintext config.
