# Modelo

<img src="Modelo/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" alt="Modelo icon">

A native macOS client for running inference against local and cloud LLMs.

Connects to **LM Studio** over your local network or Tailscale, **OpenRouter** via a dedicated endpoint, and any other **OpenAI-compatible cloud API** (Together, Mistral, etc.). Built with SwiftUI and SwiftData — no third-party dependencies.

> The name is a play on words: the app runs inference against large language **models**, and Modelo is a favorite beer. The brand mark is a 🍋‍🟩 lime.

## Features

- **Chat** — streaming responses, per-message token metrics, tool-use chip, adjustable text size; Return sends, Shift+Return inserts a newline
- **Model Picker** — grouped by server with live per-model load state (selected / loaded / idle / cloud) overlaid from the real-time poll
- **Spec strip** — parameter count, quantization, context window, and on-disk size (exact from LM Studio when available, estimated otherwise)
- **Server Status** — live latency, throughput, and request sparklines with a streaming console
- **Reports** — throughput and TTFT charts (Swift Charts) with a per-model usage table
- **Settings** — LM Studio endpoints, OpenRouter (API key only — base URL is fixed), other OpenAI-compatible cloud endpoints, personas, Firecrawl key, MCP servers
- **OpenRouter** — dedicated endpoint with model catalog parsing and a "free" filter chip
- **Personas** — system prompt presets with icons and taglines
- **MCP Servers** — built-in discovery and management of Model Context Protocol tool servers
- **Menu bar mini chat** — quick-access popover from the menu bar

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
├── ModeloApp.swift              # @main entry point
├── ContentView.swift            # NavigationSplitView shell + routing + toolbar
├── Models/                      # Server, LMStudioModel, Message, Conversation, Persona, Folder
├── Services/                    # LMStudioClient, ReachabilityMonitor, ServerRegistry,
│                                # MCPClient, FirecrawlClient, KeychainStore, Endpoint
├── Settings/                    # SettingsView + row components
└── Views/                       # Sidebar, Chat, ModelPicker, Status, Reports,
                                 # LauncherView, MenuBarChat, ModelBrowser
```

## Target

macOS 14+, SwiftUI + Swift Charts + Observation framework. No third-party packages.
