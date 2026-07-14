# Modelo

<img src="Modelo/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" alt="Modelo icon">

A native macOS client for running inference against local and cloud LLMs.

Connects to **LM Studio**, **Ollama**, **llama.cpp**, and **oMLX** over your local network or Tailscale, and to any **OpenAI-compatible cloud API** (OpenRouter, Together, Mistral, etc.). Built with SwiftUI and SwiftData.

> The name is a play on words: the app runs inference against large language **models**, and Modelo is a favorite beer. The brand mark is a 🍋‍🟩 lime.

## Features

- **Chat** — streaming responses, Markdown rendering with syntax-highlighted and copyable code blocks, per-message token metrics, slash commands (`/model`, `/temp`, `/system`, `/export`, `/skills`, …) with an autocomplete popup, queue messages while a reply streams, branch & regenerate any turn, adjustable text size
- **Artifacts** — substantial model output (HTML, SVG, Mermaid, code, documents) opens in a Claude-style side panel with live preview — see [below](#artifacts)
- **Tools & agents** — opt-in first-party filesystem + shell tools, MCP servers, `~/.agents` skills, with reliability tuned for local models — see [below](#tools--agents)
- **Multi-backend model picker** — per-server tabs in the launcher; groups by LM Studio, Ollama, llama.cpp, oMLX, and cloud; per-model load state (selected / loaded / idle / cloud); Models page shows every server Status-style for a full fleet overview
- **Endpoints** — quick-setup hints guide you through adding a new server, workspace binding scopes file-tool access per endpoint, connectivity LED on each row shows reachability at a glance, and an Advanced section collapses rarely-touched options
- **Memory** — opt-in persistent memory across conversations: the model saves and recalls named notes (`save_memory` / `read_memory`) stored as hand-editable Markdown under `~/.modelo/memory`, with global and per-project scopes; manage entries in **Settings ▸ Memory** or per project — off by default
- **Projects** — attach local directories as sidebar projects with project-scoped chats, filesystem tools, and memory
- **Server Status** — live latency, throughput, and request sparklines with a streaming console
- **Reports** — throughput and TTFT charts (Swift Charts), sortable per-model and per-server usage tables, and configurable usage retention
- **Notifications** — foreground banners appear when a reply finishes while you're in another app; tapping one deep-links straight into the relevant chat
- **Themes** — Dark (default), Light, Lager (light), Negra (dark), and Catppuccin Latte / Frappé / Macchiato / Mocha, switchable live in Settings ▸ Appearance
- **Settings** — LM Studio endpoints; cloud endpoints via provider presets (OpenAI, Groq, OpenRouter, Together, DeepSeek, Mistral) or any custom OpenAI-compatible base URL; presets/personas with icon picker; filesystem/shell tools; memory; Firecrawl key; MCP servers
- **Personas** — system prompt presets with icons and taglines, managed from their own sidebar section and applied per-chat from the composer
- **MCP Servers** — built-in discovery and management of Model Context Protocol tool servers
- **Menu bar mini chat** — quick-access popover from the menu bar

## Tools & agents

Modelo gives models a layered tool stack, designed so that even small/quantized **local** models can find and use tools reliably:

- **First-party filesystem & shell tools** — `read_file`, `write_file`, `edit_file`, `grep`, `glob`, `bash`. **Opt-in and off by default**: enable them in **Settings ▸ Tools** and pick a workspace folder (defaults to an auto-created `~/.modelo` sandbox) that all file access is confined to — path traversal is blocked. `bash` is behind its own separate toggle. Read-only tools run automatically; **writes, edits, and shell commands pause for an in-chat approval card** (Deny / Approve once / Approve for session) showing the content, diff, or command first.
- **Approvals & limits** — a configurable max tool rounds per turn, and an opt-in **YOLO mode** (global or per-chat) that auto-approves mutating tool calls and lifts the round cap.
- **MCP servers** — the standard way to add external/custom tools; managed in Settings.
- **`~/.agents` skills** — the portable, cross-tool `~/.agents/skills/<name>/SKILL.md` convention (shared with other agents on the machine), surfaced via a `use_skill` tool.
- **Local-model reliability** — a tolerant parser recovers tool calls a model emits as text (`<tool_call>…</tool_call>`, fenced JSON) when the server doesn't produce native `tool_calls`, and **progressive disclosure** shows only the most relevant tools per request plus a `find_tools` meta-tool, so a large tool set doesn't overwhelm the model.

Tools are also gated by each chat's **Tools** toggle and the model's tool-use capability.

## Artifacts

Like Claude Desktop — and deliberately **not** one artifact per code block. When a model produces substantial, self-contained content, it wraps it in an `<artifact>` block (taught by a short system instruction; opt-out in **Settings ▸ Tools ▸ Artifacts**); ordinary snippets stay inline.

- In the chat the artifact collapses to a compact, tappable **card**.
- Opening it shows a **split panel** beside the chat (the console inspector tucks away to make room) with a **live preview** for HTML / SVG / Mermaid (mermaid.js is bundled, so diagrams work offline), a **Preview ⇄ Source** toggle, highlighted source for code, and rendered Markdown for documents.
- **Versions** — re-emitting the same identifier adds a revision with `◀ v/n ▶` navigation; a **picker** in the header switches between multiple artifacts.
- A header button toggles the panel (shown once a chat has artifacts); the panel is **resizable** and its width persists. Copy + download included.

## Remote GPU telemetry (`modelo-tap`)

When your inference runs on a remote NVIDIA box (a DGX Spark, vLLM host, etc.), the
[`modelo-tap`](modelo-tap/README.md) agent exports that machine's VRAM, power, temperature,
and utilization over HTTP so Modelo can display it on the Status dashboard. It's a single
zero-dependency Rust binary that reads `nvidia-smi` *and* `/proc/meminfo` (the latter is the
only way to get correct VRAM on unified-memory boxes like the GB10).

Install and run instructions: **[`modelo-tap/README.md`](modelo-tap/README.md)**.

## Requirements

- macOS 14.0+
- A local inference backend is optional — cloud APIs work standalone. Supported backends: [LM Studio](https://lmstudio.ai), [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggerganov/llama.cpp), [oMLX](https://github.com/nidalhaddad/omlx)

## Building

```bash
xcodegen generate   # regenerates Modelo.xcodeproj from project.yml
open Modelo.xcodeproj
```

Build the **Modelo** scheme. Swift Package Manager resolves dependencies automatically on first build.

## Layout

```
Modelo/
├── ModeloApp.swift              # @main entry point
├── ContentView.swift            # NavigationSplitView shell + routing + toolbar
├── Theme.swift / ThemePalette.swift  # design tokens + selectable theme palettes
├── Models/                      # SwiftData models
│   ├── Conversation, Message, Server, LMStudioModel
│   ├── Persona, Preset, Folder, Project, UsageRecord
│   ├── GPUSnapshot, ModelContextOverride
├── Services/                    # Core logic
│   ├── ChatSession, ChatSessionStore, ChatProvider, ChatNotifier
│   ├── LMStudioClient, SSELineParser, Endpoint, ReachabilityMonitor
│   ├── ServerRegistry, ServerMonitor, NetworkScanner
│   ├── ToolRegistry, Tool, ToolCallParser, ToolSelector, FilesystemTools
│   ├── AgentsLoader, MCPClient, MCPServerManager, MCPServerConfig
│   ├── MemoryStore, MemoryTools, ProjectStore, FavoritesStore
│   ├── FirecrawlClient, FirecrawlTools
│   ├── ArtifactParser, SlashParser, TokenEstimator
│   ├── ConversationExporter, ConversationGrouping, BranchingMigration
│   ├── UsageRecorder, UsageMath, UsageRetention, ReportCalculator, MetricsRollup
│   ├── Benchmark, CrashReporter, Log
│   ├── GPUMonitor, PrometheusMonitor, PrometheusScrape
│   ├── OpenRouterCatalog, KeychainStore, Macmon
├── Resources/                   # bundled assets (e.g. mermaid.min.js for diagram previews)
├── Settings/                    # SettingsView, SamplingControls
└── Views/                       # UI layers
    ├── SidebarView, ChatView, ModelPickerView, StatusView
    ├── PersonasManagerView, MemoryManagerView, ProjectLandingView
    ├── ReportingView, BenchmarkView, LauncherView, ModelBrowserView
    ├── ArtifactPanel, ArtifactWebView
    ├── MenuBarChatView
    ├── MessageRow, ServerRow, LoadedModelRow
    ├── ConsoleInspector, ContextBar, ComposerField
    ├── MarkdownText, MetricStat
    ├── ThroughputChart, TTFTChart, ServerStatsView

modelo-tap/                      # remote GPU-metrics agent (Rust, runs on the NVIDIA box)
```

## Target

macOS 14+, SwiftUI + Swift Charts + Observation framework. Dependencies (SPM): [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), [Highlightr](https://github.com/raspu/Highlightr).

## License

MIT — see [LICENSE](LICENSE). Contribution guidelines: [CONTRIBUTING.md](CONTRIBUTING.md).
