# Design: First-class exo runtime support

**Date:** 2026-07-02
**Status:** Proposed (no code changes yet)
**Author:** Patrick + Claude

## Problem

Modelo can already talk to exo today by adding it as a generic **Cloud API** (or
any OpenAI-compatible local) endpoint, because exo serves the standard
`/v1/chat/completions` and `/v1/models`. But exo has an architectural quirk that
LM Studio, llama.cpp, oMLX, and Ollama do **not**:

> exo's `GET /v1/models` returns its **entire downloadable catalog** (~130
> models it *could* fetch from HuggingFace), not the models actually present on
> the machine. Only a handful are local, and even those return
> `404 No instance found for model <id>` until the model is *placed* (loaded)
> in exo.

So a naive integration floods the model picker with ~130 unusable entries and
lets the user select models that error on first message.

exo already exposes the "local only" view — the OpenAI endpoint just doesn't use
it by default:

| Endpoint | Returns |
|---|---|
| `GET /v1/models` | ~130 (full catalog) |
| `GET /v1/models?status=downloaded` | only local models (~10) |
| `GET /ollama/api/tags` | only local models (Ollama-shaped) |

We want to teach Modelo about exo natively rather than depend on exo's Ollama
compatibility shim or a filtering proxy.

## Goals

- Add **exo** as a first-class local runtime, selectable in "Add Endpoint".
- Show only the models that are actually **local** to the exo box (never the
  full catalog).
- Do it idiomatically, following the existing per-`ServerKind` pattern.
- No SwiftData migration risk.

## Non-goals (this pass)

- Browsing/adding exo's catalog or triggering HuggingFace downloads from Modelo.
- exo cluster topology / sharding visualisation (a possible Tier 3 later).
- Multi-node placement controls (sharding across the Mac Studio + laptop).

## Background: how the codebase is shaped

Adding a runtime is an intended extension point. Relevant facts:

- `ServerKind` (`Modelo/Services/Endpoint.swift`) is a `String`-backed enum with
  per-case `isLocal`, `displayName`, `defaultPort`. Its own doc comment says
  *"Add new local runtimes (vLLM, sglang, …) as cases here."*
- The "Add Endpoint" runtime picker and per-server runtime picker both iterate
  `ServerKind.localCases` (`SettingsView.swift:111`, `:1124`), so a new local
  case appears in the UI automatically, with its `defaultPort` seeded.
- Model fetching branches on `endpoint.kind` in
  `LMStudioClient.fetchModels` (`:50-71`) and helper path switches (`:111-114`,
  `:130-133`), and chat path in the same file (`:296-299`).
- `LMStudioModel.state` (`"loaded"` / `"not-loaded"`) already drives load-state,
  polled every 3s by `ServerMonitor.poll` (`:56-65`); `loadModel` / `unloadModel`
  actions already exist for LM Studio.
- `ServerKind` raw values are persisted in SwiftData, so a **new** case is purely
  additive — existing rows keep deserialising; no migration.

## Design

Introduce `ServerKind.exo` (raw value `"exo"`), a **local** runtime addressed by
`host:port`, default port **52415**, OpenAI-compatible `/v1` for chat. The only
behavioural difference from the other local kinds is the **model-list source**:
exo uses `GET /v1/models?status=downloaded`.

Because every `switch` over `ServerKind` in the codebase is exhaustive, the Swift
compiler will flag each site that must handle `.exo`. That turns the touchpoint
list below into a compiler-verified checklist — no site can be missed silently.

### Tier 1 — first-class exo endpoint (core of this spec)

**Touchpoints (7 files):**

1. **`Modelo/Services/Endpoint.swift`** — `ServerKind` enum:
   - Add `case exo = "exo"`.
   - `isLocal` → `true` (join the local group).
   - `displayName` → `"exo"`.
   - `defaultPort` → `52415`.
2. **`Modelo/Models/Server.swift`** — `baseURL`: add `.exo` to the
   `http://host:port` local group.
3. **`Modelo/Services/LMStudioClient.swift`**:
   - `fetchModels` (`:50-71`): `case .exo:` → fetch `/v1/models?status=downloaded`.
   - Model-path helper switches (`:111-114`, `:130-133`): `.exo` → `/v1/models`.
   - Chat path (`:296-299`): `.exo` → `/v1/chat/completions`.
4. **`Modelo/Services/ReachabilityMonitor.swift`** — poll interval: add `.exo` to
   the local group (online 10s / offline 30s).
5. **`Modelo/Settings/SettingsView.swift`** — icon switch (`~:272`): `.exo` → an
   SF Symbol (proposed `point.3.connected.trianglepath.dotted`, evoking a
   cluster); per-kind config/help switch (`~:1186`): add `.exo` (host:port form,
   no auth, plus a one-line note that models must be launched in exo).
6. **`Modelo/Views/ServerRow.swift`** — subtitle/host display: add `.exo` to the
   local `host:port` group.
7. **`Modelo/Views/ServerStatsView.swift`** — host label: add `.exo` to the local
   `host:port` group.

**Behaviour after Tier 1:** the user picks "exo" in Add Endpoint, it seeds
`localhost:52415`, the model picker shows only the local (~10) models, chat works
for any model the user has already launched in exo. Models not yet placed still
404 on first message — addressed in Tier 2.

**Edge cases:**
- exo's `/v1/models?status=downloaded` returns OpenAI-shaped rows
  (`{data:[{id, object, …}]}`). `LMStudioModel` decodes `id`/`object` and ignores
  exo's extra fields — no decoder change needed. It carries **no** per-model
  `state` field, so `ServerMonitor.poll`'s "no state → treat first model as
  loaded" fallback would mislabel one model as loaded. Acceptable in Tier 1
  (cosmetic); fixed properly in Tier 2.
- If exo is unreachable, the existing reachability path already renders the server
  offline — no new handling.

### Tier 2 — real load-state + place/unplace (follow-on, specified here)

Make exo models behave like LM Studio models in the picker and on load.

- **Load-state source:** a model is "loaded" iff exo has a placed instance for it.
  Read `GET /state` → `instances`; an instance is
  `{"MlxRingInstance": {"shardAssignments": {"modelId": "<id>", …}}}` (camelCase,
  wrapper key). Mark `modelId`s present there as loaded; downloaded-but-absent =
  idle. This replaces the Tier-1 fallback for exo.
- **Load action** (`loadModel` equivalent): `POST /place_instance` with
  `{"model_id": "<id>", "sharding": "Pipeline", "instance_meta": "MlxRing",
  "min_nodes": 1}`, then poll `/state` (or `GET /instance/await`) until the
  runner is `RunnerReady`.
- **Unload action** (`unloadModel` equivalent): `DELETE /instance/{instanceId}`
  (look up the instance id for the model from `/state`).
- **Where the exo-specific calls live:** exo's model/instance shapes differ enough
  (camelCase, wrapper keys, `/state`) that a small dedicated `ExoClient` (peer to
  `LMStudioClient`) is cleaner than threading `.exo` branches through the LM Studio
  load/unload/poll paths. `ServerMonitor` and the load/unload call sites dispatch
  to it when `kind == .exo`. Decision to confirm at plan time: dedicated
  `ExoClient` vs. `.exo` branches in existing services.
- **Optional:** auto-place on model select, so choosing an idle exo model in the
  picker loads it (mirrors the "select loads it" feel) — gated on a confirmation
  since placement consumes GBs of RAM.

**Result:** the model picker shows exo models as loaded/idle correctly, and
loading one from Modelo places it in exo, closing the "404 until placed" gap.

### Tier 3 — cluster status (out of scope, noted)

exo's `/state` also carries topology, per-node memory, and throughput. These could
feed the existing Server Status tiles / metrics later. Not part of this work.

## Data flow (Tier 1)

```
Add Endpoint (kind=.exo, host=localhost, port=52415)
        │
        ▼
Server row persisted (kindRaw="exo")
        │  ServerMonitor / model picker refresh
        ▼
LMStudioClient.fetchModels(.exo)
        │  GET http://localhost:52415/v1/models?status=downloaded
        ▼
[LMStudioModel] (only local models)  ──►  Model Picker (grouped under "exo")
        │  user sends a message
        ▼
POST http://localhost:52415/v1/chat/completions  (streaming, OpenAI-shaped)
```

## Testing

- **Unit (ModeloTests):** assert `fetchModels(.exo)` targets
  `/v1/models?status=downloaded` and chat targets `/v1/chat/completions`; assert
  `ServerKind.exo` reports `isLocal == true`, `defaultPort == 52415`,
  `displayName == "exo"`; assert `baseURL` builds `http://host:52415`.
- **Decode:** feed a captured exo `/v1/models?status=downloaded` payload through
  `ModelsResponse` and confirm it yields the expected ids with no decode error.
- **Manual:** add an exo endpoint against the running instance on `:52415`
  (already bridged with 10 local MLX models), confirm only those 10 appear, and
  chat with one that's launched in exo's dashboard.
- **Tier 2 (when built):** decode a captured `/state` instances payload; verify
  place/unplace round-trip against the live exo.

## Migration & safety

- Additive enum case only; no SwiftData schema change. Existing servers unaffected.
- No secrets: exo needs no API key (local, no auth), same as other local kinds.
- Reversible: removing the case (were we to revert) would only affect servers a
  user explicitly created as `.exo`.

## Open decisions (resolve during planning)

1. **Tier 2 client shape:** dedicated `ExoClient` vs. `.exo` branches in
   `LMStudioClient` / `ServerMonitor`. (Leaning: dedicated `ExoClient` — exo's
   camelCase `/state` and instance model differ enough to warrant isolation.)
2. **exo SF Symbol / label** — confirm icon and whether the sidebar note about
   "launch model in exo first" appears in Tier 1 or waits for Tier 2's
   place-on-load.
3. **Auto-place on select** (Tier 2) — do it, or require an explicit "Load"
   click? (Leaning: explicit, with a RAM-cost confirmation.)

## Scope of the first implementation

Per decision on 2026-07-02: **write this spec + plan only; no code yet.** Tier 1
is the intended first build; Tier 2 is specified so the plan can sequence it.
