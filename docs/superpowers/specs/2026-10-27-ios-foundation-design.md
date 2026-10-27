# Modelo for iOS — Slice 1: Foundation — Design Spec

**Date:** 2026-10-27  
**Status:** Draft — awaiting review  
**Branch:** `feature/ios`

## Overview

Modelo becomes a **full companion** app on iPhone and iPad: chat, server status, models,
and personas — everything the Mac app does except the Mac-only parts (filesystem/shell
tools, MCP, local GPU telemetry, windows/menu bar). It is distributed personally (Xcode /
TestFlight), not on the App Store.

**Data is independent per device for v1.** The iOS app has its own SwiftData store; no
iCloud/CloudKit sync. (CloudKit would constrain the schema — no unique constraints, every
property optional or defaulted — so it is a migration of its own, deferred.)

The full companion is far over AGENTS.md's ~1500-line review ceiling, so it ships as
independently reviewable slices, each with its own spec → plan → merge:

| Slice | Scope |
|---|---|
| **1. Foundation** (this spec) | iOS target, shared core compiling for iOS, SwiftData container, endpoint add/edit with reachability status |
| 2. Chat | Conversation list in the sidebar, streaming chat with Markdown, model picker, personas applied per chat; first iOS test target |
| 3. Fleet | Server status and loaded models (no GPU telemetry — it shells out via `Process`) |
| 4. Personas + polish | Personas manager, iPad split-view refinements |

Slices 2–4 are listed for orientation only; each is designed in its own spec.

## Approach: second app target sharing source files

A new `ModeloiOS` target in `project.yml` compiles the portable `Modelo/Models` and
`Modelo/Services` files **directly**, alongside a new `ModeloiOS/` folder for iOS-only app
and view code.

Rejected alternatives:

- **`ModeloCore` Swift package.** Cleanest boundary, but every shared type and member must
  become `public` — a large mechanical diff across the Mac codebase before any iOS UI
  exists. Revisit if the shared core grows enough to justify it.
- **One multiplatform target reusing Mac views.** The Mac views are deeply macOS-specific
  (`ChatView` alone is 1,946 lines; windows, `MenuBarExtra`, `NSViewRepresentable`).
  Reuse means `#if` throughout the UI and real regression risk for the Mac app.

## 1. Target and code sharing

- **Target `ModeloiOS`:** `type: application`, `platform: iOS`, deployment target
  **iOS 17.0** (the SwiftData + `@Observable` floor, matching macOS 14). Universal
  (`TARGETED_DEVICE_FAMILY: "1,2"`).
- **Bundle ID:** the same `$(PRODUCT_BUNDLE_IDENTIFIER_BASE)` as the Mac app, via the same
  `Signing.xcconfig` (and optional `Developer.xcconfig`). One ID can span iOS and macOS
  under a single app record, which also keeps universal purchase open.
- **Sources:** `ModeloiOS/` plus an **explicit list** of shared files. Slice 1 needs every
  `@Model` type (the schema must match), plus `Endpoint`, `ServerRegistry`,
  `KeychainStore`, `Log`, `ReachabilityMonitor`, `PollingLoop`, `LMStudioClient`, and
  their transitive dependencies. The exact list is determined **by compiling**, as the
  first implementation task — not by inspection.
- **Platform guards:** shared files get `#if os(macOS)` / `#if os(iOS)` only where they
  touch AppKit or UIKit. Inherently Mac-only files — `GPUMonitor`, `MCPClient`,
  `FilesystemTools`, `SessionSnapshot`, `ProjectStore` — are **excluded** from the iOS
  target, not guarded.
- **Info.plist** (`ModeloiOS/Info.plist`, explicit like the Mac's):
  - `NSAppTransportSecurity` → `NSAllowsArbitraryLoads: true` (LM Studio serves plain HTTP
    over Tailscale; same rationale as the Mac target).
  - `NSLocalNetworkUsageDescription` — iOS requires it before reaching LAN hosts; without
    it local servers fail silently.
  - Version keys mirror the Mac target (`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`).
- **Entitlements:** `ModeloiOS/ModeloiOS.entitlements` with
  `keychain-access-groups` = `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`,
  mirroring `Modelo.entitlements`, so `KeychainStore` behaves identically.
- **Schemes:** new `ModeloiOS` scheme. The `Modelo` scheme, `ModeloTests`,
  `scripts/install.sh`, and `.github/workflows/release.yml` are untouched.
- **Packages:** none for the iOS target in this slice. MarkdownUI arrives with slice 2.

## 2. App shell, data, and status

### SwiftData container

- Extract the schema list and `makeContainer(schema:storeFolder:storeURL:)` (store
  recovery: on an unopenable store, move the files aside with a timestamped folder and
  retry fresh — never delete) from `ModeloApp` into a shared `StoreBootstrap`
  (`Modelo/Services/StoreBootstrap.swift`).
- The Mac app calls `StoreBootstrap`; its ModeloDos → Modelo migration stays in
  `ModeloApp`. Mac behavior is unchanged.
- iOS opens `Application Support/Modelo/Modelo.store` (inside its sandbox) through the same
  function. A recovery alert mirrors the Mac's, telling the user where the old store went.

### No seeding

The Mac seeds a `localhost:1234` server; on iOS `localhost` is the phone. iOS starts with
no servers and shows an "Add an endpoint" empty state. `Persona.seedDefaults` is not called
in this slice (personas arrive with slice 2).

### Shell

- Root: `NavigationSplitView` — sidebar on iPad, collapses to a stack on iPhone. Mirrors
  the Mac, whose sidebar holds conversations.
- Slice 1 sidebar: an empty "No chats yet" state. A toolbar **gear** opens **Settings** as
  a sheet. Slice 2 fills the sidebar; the shell does not change.

### Reachability

- Reuse `ReachabilityMonitor` and `ServerRegistry` unchanged, except the app-activation
  hook: today it observes `NSApplication.didBecomeActive/didResignActive`; add an
  `#if os(iOS)` branch observing the `UIApplication` equivalents.
- Production probe: `LMStudioClient.probeReachable`, as on the Mac.
- Background cadence follows the existing policy (`idleInterval`). iOS suspends the app
  shortly after backgrounding; no background refresh work is added.

## 3. Endpoints (Settings)

### List

- One row per `Server`, ordered by `sortOrder`: label, runtime (`kind.displayName`),
  host, status dot (online / offline / needs key / unknown) and latency.
- **Swipe to delete**, with a confirmation, removing the server **and** its keychain secret.
- **Drag to reorder**, rewriting `sortOrder`.
- **Paused toggle** per row (`isPaused`) — stops polling, as on the Mac.
- Empty state: "Add an endpoint" with the add menu.

### Add menu (+)

- **Local runtime:** LM Studio, llama.cpp, llama-swap, oMLX, Ollama, exo
  (`ServerKind.localCases`). Picking one pre-fills `defaultPort`; changing runtime
  re-seeds the port only while it is still a default (`ServerKind.isDefaultLocalPort`).
- **Cloud:** OpenRouter and Nous Research (fixed URL — key only), the OpenAI, Groq,
  Together, DeepSeek, and Mistral presets, and a custom OpenAI-compatible base URL.
- Move the Mac's `private CloudPreset` list out of `SettingsView` into a shared file
  (`Modelo/Services/CloudPreset.swift`) so both apps read one list. Mac UI unchanged.

### Edit form

A standard iOS `Form`:

- **Local:** label, host, port, optional connection subtitle (`connectionID`). Host input
  is normalized by `Server.normalizedHost` (keeps `https://`, strips `http://`, trims).
- **Cloud:** label, base URL (hidden when `kind.hasFixedURL`), API key in a `SecureField`,
  stored via `KeychainStore` under `Endpoint.keychainAccount(for:)` — never in SwiftData.
- **Test connection** button: one probe, result shown inline.

### Deliberately out of scope for slice 1

- `metricsAgentURL`, `prometheusURL`, `localGPU` — telemetry is slice 3; no local GPU on iOS.
- Per-model context-length overrides.
- **Scan Network…** — needs Bonjour / LAN-scan permissions; add later if wanted.

## 4. Testing and validation

### Automated

- Shared logic is covered by the existing **macOS** `ModeloTests` (same source).
- `StoreRecoveryTests` is updated to exercise `StoreBootstrap`.
- One new test: every `CloudPreset` has a non-empty name and a base URL that parses with an
  `https` scheme.
- **No iOS test target in this slice** — the iOS code is thin views over shared, tested
  logic. Slice 2 adds one when chat brings iOS-specific state.

### Gates (every task)

- Mac build + full suite green:
  `xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test`
- iOS build green:
  `xcodebuild -project Modelo.xcodeproj -scheme ModeloiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`
  (generic destination: this machine has iOS 27 / iPhone 18 Pro simulators, not the
  iPhone 16 named in the workspace CLAUDE.md).
- Run `xcodegen generate` after any `project.yml` change.

### Manual (Patrick, on device)

1. Install on iPhone from Xcode.
2. Add an LM Studio endpoint by Tailscale hostname → the Local Network prompt appears; the
   row turns green with a latency.
3. Add an OpenRouter key → "needs key" becomes online; the key survives a reinstall.
4. Pause a server, background the app, return → polling stops and resumes correctly.
5. iPad → split view shows a sidebar.

### Size

Expected well under the ~1500-line ceiling: roughly 400–600 lines of iOS app/view code,
plus small Mac refactors (`StoreBootstrap`, `CloudPreset`, `#if os` guards in
`ReachabilityMonitor` and any other shared file the compile step surfaces).
