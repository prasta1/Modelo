# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Regenerate Modelo.xcodeproj from project.yml (required after adding/removing files)
xcodegen generate

# Build (CLI)
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' build

# Run all tests
xcodebuild -project Modelo.xcodeproj -scheme ModeloTests -destination 'platform=macOS' test

# Run a single test class
xcodebuild -project Modelo.xcodeproj -scheme ModeloTests -destination 'platform=macOS' \
  -only-testing:ModeloTests/ChatSessionTests test
```

Two SPM packages are declared in `project.yml`: **MarkdownUI** (`swift-markdown-ui`) for message rendering and **Highlightr** for syntax highlighting inside code fences.

## Architecture

### Data layer — SwiftData

`ModeloApp.swift` builds a `ModelContainer` from the schema at `~/Library/Application Support/Modelo/Modelo.store`. Six models: `Server`, `Conversation`, `Message`, `UsageRecord`, `Persona`, `Folder`.

**Critical SwiftData gotcha:** SwiftData bakes property-default expressions into the schema as compile-time constants. `Conversation.id` (UUID) and `Conversation.createdAt` (Date) must be assigned explicitly in `init` — otherwise every instance shares the same value. Always use `persistentModelID` (not `id`) for identity, view keys, and lookups. `Conversation.id` is kept only to avoid a migration; it is **not** unique for historical rows.

SwiftData to-many relations are unordered — `conversation.messages` must be sorted by `createdAt` before sending on the wire or for any display that depends on order.

### Server kinds & `Endpoint`

Three server kinds are defined in `Services/Endpoint.swift` and `Models/Server.swift`:

| Kind | URL | Auth |
|---|---|---|
| `lmStudio` | `http://host:port` | none |
| `cloudAPI` | user-supplied HTTPS base | bearer token (Keychain) |
| `openRouter` | `https://openrouter.ai/api/v1` (fixed) | API key (Keychain) |

`Endpoint` is a `Sendable` value-type snapshot of a `Server`, built on the `MainActor` before crossing actor boundaries. This is the required pattern everywhere networking reads server properties — reading `@Model` properties off the main actor is a data race under Swift 6.

API keys live in the Keychain under service `com.peregrine.modelo`, **never** in the SwiftData store.

`NSAllowsArbitraryLoads: true` is set in `Info.plist` to allow plain HTTP to LM Studio over Tailscale.

### Chat backend — `ChatProvider` / `LMStudioClient`

`ChatProvider` (`Services/ChatProvider.swift`) is the protocol for chat backends. `LMStudioClient` (`Services/LMStudioClient.swift`) is the single concrete implementation and is used as `LMStudioClient.shared` throughout. It handles all three server kinds:

- LM Studio: prefers `/api/v0/models` (rich metadata), falls back to `/v1/models`; streaming chat at `/v1/chat/completions`
- OpenRouter / Cloud API: `/models` and `/chat/completions` with bearer auth
- LM Studio model load/unload/pin via `/api/v0/models/{id}/load|unload`

The streaming path uses `URLSession.bytes` + SSE line parsing (`Services/SSELineParser.swift`). Tool call fragments are accumulated by index across deltas and yielded as a single `.toolCalls` event on `finish_reason: "tool_calls"`.

### Agentic loop — `ChatSession`

`ChatSession` (`Services/ChatSession.swift`) drives one streaming turn. It:

1. Appends the user message to SwiftData
2. Streams the assistant reply, flushing tokens to the `@Observable` `Message` at ~20 fps (not per-token, to avoid layout thrash)
3. If the model returns tool calls, dispatches them through `ToolRegistry`, appends `tool`-role messages, and re-streams — up to **5 rounds** (`maxToolRounds`)
4. Records a `UsageRecord` and fires an auto-title run on the first exchange

The 20 fps flush is intentional: flushing every token caused excessive SwiftUI layout passes. The token buffer is flushed immediately on the first token to preserve TTFT accuracy.

### Tool system

`Tool` protocol (`Services/Tool.swift`): `name`, `description`, `parameters` (JSON Schema), `execute(argumentsJSON:) async throws -> String`.

`ToolRegistry` holds the active tools and is passed into `ChatSession`. Tools are built from two sources:

- **Built-in Firecrawl** (`Services/FirecrawlTools.swift`): `firecrawl_scrape` and `firecrawl_search`, enabled when a Firecrawl API key is in the Keychain
- **MCP** (`Services/MCPClient.swift`, `MCPServerManager.swift`): each enabled MCP server is spawned as a subprocess at app start; discovered tools are wrapped as `MCPTool` and merged into the registry

`MCPClient` is a Swift `actor` speaking JSON-RPC 2.0 over stdio. `MCPServerManager` (main-actor `@Observable`) owns client lifetimes and exposes `availableTools`.

### Reachability & monitoring

- `ReachabilityMonitor` — probes servers on a schedule (10 s when online, 30 s when offline) using a lightweight GET to `/v1/models`. Updates `ServerRegistry`.
- `ServerRegistry` — main-actor `@Observable` holding transient per-server status and latency. This is the UI's source of truth for the status dot; it is **not** persisted.
- `ServerMonitor` — polls LM Studio servers every 3 s for loaded-model state, feeding the live dot in the model picker and the console inspector.

### View hierarchy

`ContentView` is a `NavigationSplitView` with a `SidebarRoute` enum (`launcher`, `status`, `reports`, `settings`, `conversation(PersistentIdentifier)`). Route is persisted to `@SceneStorage` and restored on launch.

Menu commands bridge to `ContentView` state via `@FocusedValue` — the `ModeloCommands` bundle is published while the window is frontmost and consumed by the `CommandGroup`/`CommandMenu` items declared in `ModeloApp`.

The menu-bar popover (`Views/MenuBarChatView.swift`) shares `LMStudioClient.shared` and `ServerRegistry` with the main window, but its messages are **ephemeral** (in-memory only, no SwiftData) and tools are disabled.

### Theme

All design tokens (colors, fonts, spacing) are in `Theme.swift`. The app is always dark-mode (`preferredColorScheme(.dark)`). Use `Theme.Palette.*` for colors and `Theme.metric(_:)` for metric/label fonts.

## Agent skills

### Issue tracker

GitHub issues in this repo; external GitHub pull requests are **not** treated as a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The skill uses the following labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout with a root `CONTEXT.md` and a `docs/adr/` directory. See `docs/agents/domain.md`.
