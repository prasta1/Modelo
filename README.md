# Modelo

<img src="Modelo/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" alt="Modelo icon">

[![Latest release](https://img.shields.io/github/v/release/prasta1/Modelo)](https://github.com/prasta1/Modelo/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

**A native macOS client for local and cloud LLMs — one model picker for your own hardware and every OpenAI-compatible API.**

<!-- SCREENSHOT PLACEHOLDER: hero — main window mid-conversation, sidebar + chat + artifact panel open.
     Save as docs/screenshots/hero.png (~2400px wide, retina), then uncomment:
<img src="docs/screenshots/hero.png" alt="Modelo chatting with a local model, artifact panel open">
-->

> The name is a play on words: the app runs inference against large language **models**, and Modelo is a favorite beer. The brand mark is a 🍋‍🟩 lime.

## Install

Download `Modelo-vX.Y.Z.zip` from the **[latest release](https://github.com/prasta1/Modelo/releases/latest)**, unzip it, and drag `Modelo.app` to `/Applications`. Builds are signed with Developer ID and notarized by Apple, so they open without Gatekeeper warnings. Universal binary (Apple Silicon + Intel), macOS 14+.

You'll need at least one [endpoint](#endpoints) — a local runtime, a cloud API key, or both.

## Features

- **Chat** — streaming Markdown with highlighted code, branch & regenerate any turn, queue messages mid-reply, slash commands (`/model`, `/temp`, `/system`, `/export`, …), and decode + end-to-end tok/s on every reply
- **Vision** — paste or drag images into the composer for vision-capable models
- **[Artifacts](#artifacts)** — HTML, SVG, Mermaid, code, and documents open in a side panel with live preview, versions, and export
- **[Tools & agents](#tools--agents)** — opt-in filesystem + shell tools with approval cards, MCP servers, `~/.agents` skills, tuned so small local models can use them
- **[Endpoints](#endpoints)** — six local runtimes and seven cloud providers in one picker; **Scan Network…** finds local servers for you
- **Model picker** — endpoint sidebar with Free / Loaded filters, per-model load state, and unload for LM Studio and llama-swap
- **Memory & Projects** — opt-in persistent memory as hand-editable Markdown; attach local folders as projects with scoped chats, tools, and memory
- **Status & Reports** — live latency/throughput sparklines, a streaming console, and per-model / per-server usage charts
- **Personas** — system-prompt presets with icons, applied per chat
- **Menu bar mini chat**, finished-reply notifications, and nine themes (Dark, Light, Lager, Negra, One Dark Pro, Catppuccin ×4)

<!-- SCREENSHOT PLACEHOLDER: model picker — endpoint sidebar with several local + cloud endpoints.
     Save as docs/screenshots/picker.png, then uncomment:
<img src="docs/screenshots/picker.png" alt="Model picker grouping local and cloud endpoints">
-->

**Shortcuts:** <kbd>Esc</kbd> stops a streaming reply · <kbd>⌘L</kbd> focuses the composer · <kbd>⌘\\</kbd> toggles the artifacts panel.

## Endpoints

Everything Modelo talks to speaks the OpenAI-compatible `/v1` wire protocol, so local runtimes and cloud providers sit side by side in the same model picker and you can switch mid-conversation. Add one from **Settings ▸ Endpoints ▸ Add Endpoint**, or let **Scan Network…** discover local servers on your subnet.

### Local runtimes

Self-hosted backends addressed by `host:port` — no API key, no data leaving your hardware.

| Runtime | Default port | Notes |
| --- | --- | --- |
| [LM Studio](https://lmstudio.ai) | 1234 | Load a model, then start the server from LM Studio's Developer tab. Modelo also reads LM Studio's richer `/api/v0` for load state and true context sizes. |
| [Ollama](https://ollama.com) | 11434 | `ollama pull llama3.2` — the server runs on its own. |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | 8080 | `llama-server -m model.gguf --port 8080` |
| [llama-swap](https://github.com/mostlygeek/llama-swap) | 8080 | Reverse proxy that hot-swaps between several llama.cpp backends behind one address. |
| [oMLX](https://omlx.ai) | 8000 | Apple-silicon MLX runtime — load a model in the app and tap Start Server. |
| [exo](https://exolabs.net) | 52415 | Clusters several Macs into one runtime. Launch models from exo's dashboard first. |

The machine doesn't have to be on your LAN: a box on your **[Tailscale](https://tailscale.com)** tailnet works identically — enter its tailnet IP or MagicDNS name (`gpu-box.tailnet-name.ts.net`) as the host, with no ports exposed to the internet.

### Cloud APIs

Bearer-token endpoints; keys are stored in the macOS Keychain, never in plaintext.

| Provider | Setup |
| --- | --- |
| [Nous Research](https://nousresearch.com) | Dedicated endpoint — base URL is fixed, so you only paste a key. |
| [OpenRouter](https://openrouter.ai) | Dedicated endpoint — key only. Pulls OpenRouter's catalog for context length, tool/vision capability, and free-tier flags. |
| [OpenAI](https://platform.openai.com) | Preset — `api.openai.com/v1` |
| [Groq](https://groq.com) | Preset — `api.groq.com/openai/v1` |
| [Together.ai](https://together.ai) | Preset — `api.together.xyz/v1` |
| [DeepSeek](https://deepseek.com) | Preset — `api.deepseek.com/v1` |
| [Mistral](https://mistral.ai) | Preset — `api.mistral.ai/v1` |
| **Custom…** | Any other OpenAI-compatible base URL (Fireworks, Cerebras, Hyperbolic, a corporate gateway, …). |

## Tools & agents

A layered tool stack, designed so even small/quantized **local** models can find and use tools reliably:

- **Filesystem & shell** — `read_file`, `write_file`, `edit_file`, `grep`, `glob`, `bash`. **Off by default**: enable in **Settings ▸ Tools** and pick a workspace folder that all file access is confined to. Reads run automatically; **writes, edits, and shell commands pause for an approval card** showing the content, diff, or command first. An opt-in **YOLO mode** (global or per chat) auto-approves.
- **MCP servers** — the standard way to add external tools; managed in Settings.
- **`~/.agents` skills** — the cross-tool `~/.agents/skills/<name>/SKILL.md` convention, surfaced via a `use_skill` tool.
- **Local-model reliability** — a tolerant parser recovers tool calls emitted as text (`<tool_call>…`, fenced JSON), and **progressive disclosure** shows only the most relevant tools per request plus a `find_tools` meta-tool.

## Artifacts

Like Claude Desktop — and deliberately **not** one artifact per code block. Substantial, self-contained output is wrapped in an `<artifact>` block and collapses to a card in the chat; ordinary snippets stay inline (opt out in **Settings ▸ Tools ▸ Artifacts**).

- Opens in a **resizable side panel** with live preview for HTML / SVG / Mermaid (bundled, so it works offline) and a Preview ⇄ Source toggle.
- **Versions** — re-emitting the same identifier adds a revision with `◀ v/n ▶` navigation.
- **Export** — copy, download, open in your browser, or save as PNG.

<!-- SCREENSHOT PLACEHOLDER: artifact panel — an HTML or Mermaid artifact in live preview beside the chat.
     Save as docs/screenshots/artifact.png, then uncomment:
<img src="docs/screenshots/artifact.png" alt="An HTML artifact rendered in the side panel">
-->

## Remote GPU telemetry (`modelo-tap`)

When inference runs on a remote NVIDIA box (a DGX Spark, a vLLM host, …), the [`modelo-tap`](modelo-tap/README.md) agent — a single zero-dependency Rust binary — exports its VRAM, power, temperature, and utilization so Modelo can show them on the Status dashboard. Setup: **[`modelo-tap/README.md`](modelo-tap/README.md)**.

## Building from source & contributing

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for build, test, and PR workflow. Short version: `brew install xcodegen && xcodegen generate`, then build the **Modelo** scheme in Xcode 26+.

## License

MIT — see [LICENSE](LICENSE).
