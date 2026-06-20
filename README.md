# Modelo

<img src="Modelo/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" alt="Modelo icon">

A native macOS client for running inference against local and cloud LLMs.

Connects to **LM Studio** over your local network or Tailscale, **OpenRouter** via a dedicated endpoint, and any other **OpenAI-compatible cloud API** (Together, Mistral, etc.). Built with SwiftUI, SwiftData, and Swift Charts — no third-party packages.

> The name is a play on words: the app runs inference against large language **models**, and Modelo is a favorite beer. The brand mark is a 🍋‍🟩 lime.

## Highlights

- Streaming chat with token metrics, TTFT, vision attachments, and agentic tool use
- Built-in **Firecrawl** scrape + search tools, plus full **MCP** (Model Context Protocol) tool forwarding over stdio
- LM Studio model load / unload / keep-in-RAM from the picker; live reachability and throughput monitoring
- Conversation folders, pinning, per-conversation system prompt, temperature, and tool toggle
- Reports view with throughput, TTFT, per-model and per-server breakdowns over 7 / 30 / all-time windows
- Menu-bar mini chat for quick one-off exchanges

## Providers

Three server kinds are first-class (`Services/Endpoint.swift`, `Models/Server.swift`):

| Kind | Base URL | Auth | Reach polling | Load state |
|---|---|---|---|---|
| **LM Studio** | `http://host:port` (default `1234`) | none | 10 s online / 30 s offline | yes — live loaded/idle dot |
| **OpenRouter** | `https://openrouter.ai/api/v1` (fixed) | API key (Keychain) | 30 s | n/a |
| **Cloud API** | user-supplied OpenAI-compatible base URL | bearer token (Keychain) | 30 s | n/a |

Reachability probes hit `/v1/models` (or `/models`) with a 4 s timeout and record latency. LM Studio servers are additionally polled every 3 s by `ServerMonitor` to surface the currently loaded model in the picker.

API keys are never persisted in SwiftData — they live in the Keychain under service `com.peregrine.modelo` (`Services/KeychainStore.swift`).

## Tools

Modelo runs a real agentic loop in `Services/ChatSession.swift`. When the model returns `finish_reason: "tool_calls"`, each call is dispatched through `ToolRegistry`, results are streamed back as `tool`-role messages, and the model is re-prompted — up to **5 rounds per turn**. The per-conversation `toolsEnabled` toggle disables this entirely.

### Built-in: Firecrawl

Two tools are exposed when a Firecrawl API key is configured (Settings → Tools):

- **`firecrawl_scrape`** — `POST https://api.firecrawl.dev/v1/scrape` with `formats: ["markdown"]`; returns the rendered page as markdown.
- **`firecrawl_search`** — `POST https://api.firecrawl.dev/v1/search`; returns title / URL / snippet results.

Implementation: `Services/FirecrawlClient.swift`, `Services/FirecrawlTools.swift`. The key is stored in Keychain under account `firecrawl`.

### MCP (Model Context Protocol)

Modelo speaks MCP over **stdio** as a client (`Services/MCPClient.swift`, `MCPServerManager.swift`):

- Each enabled MCP server is spawned as a subprocess at app start with its configured command, arguments, and env vars (e.g. `GITHUB_PERSONAL_ACCESS_TOKEN`).
- Handshake follows the JSON-RPC 2.0 spec: `initialize` → `notifications/initialized` → `tools/list`.
- Discovered tool definitions are wrapped as `MCPTool` and merged into the same `ToolRegistry` the built-in tools use, so the model sees them in the OpenAI-compatible `tools` array.
- Tool invocations route through `MCPClient.callTool(name:argumentsJSON:)`, which issues `tools/call` and reconstructs text from the response's `content` array.
- A discovery catalog in Settings provides one-click adds for common servers; you can also configure any arbitrary command.

Stderr from MCP processes is drained but ignored; stdout carries the JSON-RPC stream.

## Chat

`Views/ChatView.swift` + `Services/ChatProvider.swift` + `Services/SSELineParser.swift`.

- **Streaming** via SSE; deltas are buffered and flushed to the UI at ~20 fps to avoid layout thrash.
- **TTFT** captured on the first token; **tok/s** computed from completion tokens ÷ elapsed since first token.
- **Usage frames** parsed for prompt + completion token counts and shown per message.
- **Vision attachments** — user messages can include images, serialized as `data:image/...;base64,...` and sent in OpenAI multimodal format (`type: "image_url"`).
- **Tool-call rendering** — assistant tool calls are persisted in `Message.toolCallsJSON` and rendered inline; tool responses are persisted as `tool`-role messages with `toolCallID` + `toolName`.
- **Composer** — Return sends, Shift+Return inserts a newline.
- **Adjustable text size** — ⌘+ / ⌘- / ⌘0 (15–25 pt).

## Models

The model picker (`Views/ModelPickerView.swift`) groups by server with live state: **selected / loaded / idle / cloud**. The loaded dot reflects the 3 s `ServerMonitor` poll, not a stale fetch.

The **spec strip** (`Models/LMStudioModel.swift`) displays:

- `familyName`, `arch`, `quantization`
- Context window (`maxContextLength` / `loadedContextLength`)
- On-disk size — exact from LM Studio's `size_bytes` when available, otherwise estimated from parameter count × quantization bit-depth (shown with `~` prefix)
- Publisher (e.g. `lmstudio-community`)

Derived capabilities (used for filtering and badges):

- `supportsVision` — from API `type: "vlm"` or name heuristics (`-vl`, `llava`, `pixtral`, …)
- `supportsToolUse` — authoritative from OpenRouter's `supported_parameters`; assumed for non-embedding LM Studio models
- `supportsThinking` — heuristic match for reasoning models (`deepseek-r`, `qwq`, `qwen3`, …)
- `isEmbeddingModel` — filtered out of chat lists
- `isFree` — set from OpenRouter pricing data

**Model browser** (`Views/ModelBrowserView.swift`) — searchable list for cloud endpoints with Free / Tools / Vision filter chips. The "free" chip is suppressed for LM Studio.

**LM Studio model control** (`Services/LMStudioClient.swift`):

- `POST /api/v0/models/{id}/load` — load
- `POST /api/v0/models/{id}/unload` — eject (button shows a spinner until the call returns)
- `POST /api/v0/models/{id}/load` with `{ "keep_in_ram": bool }` — pin / unpin

## Status & Reports

**Status** (`Views/StatusView.swift`) — grid of server cards showing a status LED (LIVE / OFFLINE / PROBING), name, latency, loaded model count, request count, throughput, and a throughput sparkline computed from the last 20 usage records via `InferenceRollup`.

**Console inspector** — right-side panel toggled by ⌘I, streaming live metrics for the active conversation's server.

**Reports** (`Views/ReportingView.swift`, `Services/ReportCalculator.swift`) — per-turn `UsageRecord`s (`Models/UsageRecord.swift`) drive:

- Time-window filter: **7 days / 30 days / all time**
- Summary tiles: Requests, Tokens, Avg tok/s, Peak tok/s, Avg TTFT
- Daily line charts (Swift Charts): Requests, Tokens, Avg tok/s
- Per-model and per-server tables with token-share bars

## Conversations

`Models/Conversation.swift`, `Folder.swift`, `Message.swift`.

- **Folders** — group conversations; `.nullify` delete rule keeps conversations when a folder is removed
- **Pinning** — `isPinned` floats conversations to the top of the sidebar
- **Sidebar grouping** (`Services/ConversationGrouping.swift`) — Pinned → Folder → Date buckets
- **Per-conversation overrides** — `systemPrompt`, `temperature` (default 0.7), `toolsEnabled` (default on), `contextTokensUsed`
- **Title** — auto-generated on first turn, manually editable

## Personas

System-prompt presets (`Models/Persona.swift`) with name, SF Symbol icon, tagline, and prompt. Five seeded on first launch: **Assistant, Customer Support, Coding, Researcher, Investor**. Selecting a persona from the launcher applies it as the new conversation's `systemPrompt`. Reorderable from Settings → Personas.

## Menu bar mini chat

`Views/MenuBarChatView.swift` — 380 × 480 popover from the menu bar (bottle icon). Shares `LMStudioClient` and `ServerRegistry` with the main window but messages are **ephemeral** (in-memory only, no SwiftData) and **tools are disabled**. Includes a model picker, clear button, and "open in Modelo" handoff.

## Settings

Tabs in `Settings/SettingsView.swift`:

- **Servers** — LM Studio hosts / ports
- **Cloud APIs** — OpenRouter and generic OpenAI-compatible endpoints
- **Personas** — manage prompt presets, drag to reorder
- **Tools** — Firecrawl API key
- **MCP Servers** — configure subprocesses (command, args, env), enable/disable, optional discovery catalog

The Settings window is resizable; secrets are written to the Keychain, never to the SwiftData store.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New chat |
| ⌘I | Toggle console inspector |
| ⌘+ / ⌘- / ⌘0 | Message text size |
| Return | Send |
| Shift+Return | Newline |

Plus a **Go** command menu for jumping to Launcher / Status / Reports.

## Storage

SwiftData store: `~/Library/Application Support/Modelo/Modelo.store`. On first launch the app migrates the legacy `ModeloDos.store` to this location. Schema: `Server`, `Conversation`, `Message`, `UsageRecord`, `Persona`, `Folder`.

## Requirements

- macOS 14.0+
- [LM Studio](https://lmstudio.ai) for local inference (optional — cloud APIs work standalone)

## Building

```bash
xcodegen generate   # regenerates Modelo.xcodeproj from project.yml
open Modelo.xcodeproj
```

Build the **Modelo** scheme. No dependencies to install.

## Layout

```
Modelo/
├── Theme.swift                  # design tokens, shared controls, Color(hex:)
├── ModeloApp.swift              # @main entry point, scenes, SwiftData container
├── ContentView.swift            # NavigationSplitView shell + routing + toolbar
├── Models/                      # Server, LMStudioModel, Message, Conversation,
│                                # Persona, Folder, UsageRecord
├── Services/                    # LMStudioClient, ChatSession, ChatProvider,
│                                # SSELineParser, Endpoint, OpenRouterCatalog,
│                                # Tool / ToolRegistry, FirecrawlClient + Tools,
│                                # MCPClient + ServerManager + ServerConfig,
│                                # ReachabilityMonitor, ServerMonitor, ServerRegistry,
│                                # MetricsRollup, ReportCalculator, UsageRecorder,
│                                # UsageMath, ConversationGrouping, KeychainStore
├── Settings/                    # SettingsView + row components per tab
└── Views/                       # Sidebar, Chat, ModelPicker, ModelBrowser,
                                 # Status, Reporting, Launcher, MenuBarChat,
                                 # ConsoleInspector, ContextBar, charts, rows
```

## Target

macOS 14+, SwiftUI + SwiftData + Swift Charts + Observation framework. No third-party packages.
