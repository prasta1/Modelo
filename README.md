# Modelo

<img src="Modelo/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" alt="Modelo icon">

A native macOS client for running inference against local and cloud LLMs.

Connects to **LM Studio** over your local network or Tailscale, and to any **OpenAI-compatible cloud API** (OpenRouter, Together, Mistral, etc.). Built with SwiftUI and SwiftData.

> The name is a play on words: the app runs inference against large language **models**, and Modelo is a favorite beer. The brand mark is a 🍋‍🟩 lime.

## Features

- **Chat** — streaming responses, Markdown rendering with syntax-highlighted and copyable code blocks, per-message token metrics, tool-use chip, adjustable text size
- **Model Picker** — grouped by server with per-model load state (selected / loaded / idle / cloud)
- **Server Status** — live latency, throughput, and request sparklines with a streaming console
- **Reports** — throughput and TTFT charts (Swift Charts) with a per-model usage table
- **Settings** — LM Studio endpoints, cloud API endpoints (any OpenAI-compatible base URL), personas, Firecrawl key, MCP servers
- **Personas** — system prompt presets with icons and taglines
- **MCP Servers** — built-in discovery and management of Model Context Protocol tool servers
- **Menu bar mini chat** — quick-access popover from the menu bar

## Requirements

- macOS 14.0+
- [LM Studio](https://lmstudio.ai) for local inference (optional — cloud APIs work standalone)

## Building

```bash
xcodegen generate   # regenerates Modelo2.xcodeproj from project.yml
open Modelo2.xcodeproj
```

Build the **Modelo2** scheme. Swift Package Manager resolves dependencies automatically on first build.

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

macOS 14+, SwiftUI + Swift Charts + Observation framework. Dependencies (SPM): [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), [Highlightr](https://github.com/raspu/Highlightr).
