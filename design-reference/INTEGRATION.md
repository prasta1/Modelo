# Modelo — Native Refined UI (handoff implementation)

This folder implements the **design layer** from `project/SwiftUI Handoff.md`
(the "Native Refined" screens), laid out to match your existing `Modelo.xcodeproj`
group structure so the files drop straight in.

## What's here (files I authored)

```
Modelo/
├── Theme.swift                 # tokens, Color(hex:), Font.mono, ModeloMark, PillToggle, SegmentedPills, Eyebrow
├── AppStore.swift              # NEW FILE — single source of truth (Observation) + seed data
├── ModeloApp.swift             # @main: WindowGroup + MenuBarExtra(.window)
├── ContentView.swift           # NavigationSplitView shell + Section routing + toolbar
├── Models/
│   ├── Server.swift            # Server, ServerKind, ServerStat
│   ├── LMStudioModel.swift     # ModelInfo, ModelState, CatalogModel
│   ├── Message.swift           # ChatMessage, Role, ToolCall, MessageMetrics
│   ├── Conversation.swift      # Conversation
│   └── Persona.swift           # Persona
├── Settings/
│   └── SettingsView.swift
└── Views/
    ├── SidebarView.swift       # §3
    ├── ChatView.swift          # §5 (composer included)
    ├── ContextBar.swift        # §5.1
    ├── MessageRow.swift        # §5.2 (+ InlineChip, BlinkingCaret)
    ├── ModelPickerView.swift   # §8
    ├── LoadedModelRow.swift    # §8 row
    ├── StatusView.swift        # §6
    ├── ServerRow.swift         # §6 card (+ Sparkline)
    ├── ConsoleInspector.swift  # §6 console
    ├── MetricStat.swift        # §6 2×2 metric cell
    ├── ReportingView.swift     # §6 reports
    ├── ThroughputChart.swift   # §6 (Swift Charts)
    ├── TTFTChart.swift         # §6 (Swift Charts)
    ├── MenuBarChatView.swift   # §7 popover contents
    └── ModelBrowserView.swift  # the "01 Native Refined" model grid (bonus; not routed by default)
```

## To wire it up

1. **Add `AppStore.swift` to the Modelo target** — it's the only file not already
   referenced in your `project.pbxproj`. Everything else maps to an existing slot.
2. These files **define the model types** (`Server`, `ModelInfo`, `ChatMessage`,
   `Conversation`, `Persona`, etc.). If your real `Models/*.swift` already declare
   types with these names, reconcile signatures — don't keep two definitions.
3. The **seed data in `AppStore.init()` are the mock's sample frames.** Replace them
   with your live sources: `ServerMonitor` (status cards + console), `ReportCalculator` /
   `MetricsRollup` (reports), `ChatSession` (messages/streaming), `ServerRegistry`
   (servers/models). Per the handoff, stream these in rather than holding static arrays.
4. **Services layer is untouched** (LMStudioClient, MCPClient, SSELineParser, Keychain,
   monitors, etc.) — that's app logic, out of the design handoff's scope.

## Replace before shipping (handoff §9 "what NOT to port")

- `ModeloMark` uses the 🍋‍🟩 emoji — swap for `Image("ModeloMark")` and a **template**
  (monochrome) menu-bar asset (`ModeloMenuBarIcon`, `isTemplate = true`).
- Traffic lights / 46px titlebar / menu-bar / notch are **native chrome** — not drawn here.
- Hand-drawn SVG charts → Swift Charts (done: `ThroughputChart`, `TTFTChart`, `Sparkline`).

## Target

macOS 14+, SwiftUI + Swift Charts + Observation. No third-party deps; Geist → SF Pro,
Geist Mono → SF Mono (no bundled fonts).
