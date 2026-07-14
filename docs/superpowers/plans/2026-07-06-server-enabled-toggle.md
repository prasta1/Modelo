# Per-Server Enabled Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `isEnabled` toggle to each configured server so a disabled server disappears from the chat/menu-bar pickers and stops all background polling, while staying configured in Settings.

**Architecture:** A new `isEnabled: Bool = true` field on the `Server` SwiftData model (lightweight migration), enforced by filtering `servers.filter(\.isEnabled)` at the seams where server lists enter subsystems — monitor startup, model discovery, menu-bar discovery, and the status dashboard. A `discoverySignature` helper on `Server` feeds ContentView's `serverDiscoveryKey` so flipping the toggle re-runs discovery and restarts monitors live. The monitor services themselves are untouched.

**Tech Stack:** Swift / SwiftUI / SwiftData, XcodeGen-generated Xcode project, XCTest (`ModeloTests`).

**Spec:** `docs/superpowers/specs/2026-07-06-server-enabled-toggle-design.md`

## Global Constraints

- **Work in a git worktree off `origin/main`** on branch `feature/server-enabled-toggle` (this checkout is shared by concurrent sessions — never commit from the primary checkout). Create via the superpowers:using-git-worktrees skill.
- **The Xcode project is generated and gitignored.** In a fresh worktree run `xcodegen generate` once before building. No new source files are added by this plan, so no re-generation is needed afterward.
- **Build (compile check):** `xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` — green ends in `** BUILD SUCCEEDED **`; any `error:` line is a hard failure.
- **Test:** `xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` (append `-only-testing:ModeloTests/ServerRegistryTests` for the fast loop).
- **Diff ceiling ~1500 lines** (AGENTS.md); this plan lands well under it.
- Settings intentionally still lists disabled servers — do NOT filter `SettingsView`'s query.
- Per AGENTS.md this is a schema + UI change: pause for human review before merge; do not merge to main without the user's explicit say-so.

---

### Task 1: `Server.isEnabled` field + `discoverySignature` helper

**Files:**
- Modify: `Modelo/Models/Server.swift` (fields around line 30, methods around line 42)
- Test: `ModeloTests/ServerRegistryTests.swift` (existing file — add tests; creating a new test file would require regenerating the Xcode project)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Server.isEnabled: Bool` (stored, default `true`) and `Server.discoverySignature(isOnline: Bool) -> String`, used by Task 2.

- [ ] **Step 1: Bring the spec and plan into the worktree and commit them**

The spec/plan live only in the primary checkout's working tree. From the worktree root:

```bash
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp /Users/prasta/Projects/personal/apps/active/modelo/docs/superpowers/specs/2026-07-06-server-enabled-toggle-design.md docs/superpowers/specs/
cp /Users/prasta/Projects/personal/apps/active/modelo/docs/superpowers/plans/2026-07-06-server-enabled-toggle.md docs/superpowers/plans/
git add docs/superpowers
git commit -m "docs: spec and plan for per-server enabled toggle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write the failing tests**

Append inside the `ServerRegistryTests` class in `ModeloTests/ServerRegistryTests.swift` (follow the existing style — `makeContext()` builds the in-memory container):

```swift
    func test_server_defaultsToEnabled_andPersistsDisabled() throws {
        let context = try makeContext()
        let server = Server(label: "Spark", host: "spark")
        // New servers (and existing rows after migration) must default to enabled.
        XCTAssertTrue(server.isEnabled)
        server.isEnabled = false
        context.insert(server)
        try context.save()
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<Server>()).first)
        XCTAssertFalse(fetched.isEnabled)
    }

    func test_discoverySignature_changesWhenEnabledFlips() {
        // ContentView re-runs discovery and restarts monitors when this string
        // changes — flipping isEnabled must therefore change it.
        let server = Server(label: "Spark", host: "spark")
        let before = server.discoverySignature(isOnline: true)
        server.isEnabled = false
        XCTAssertNotEqual(before, server.discoverySignature(isOnline: true))
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test -only-testing:ModeloTests/ServerRegistryTests`

Expected: **BUILD FAILED** — `value of type 'Server' has no member 'isEnabled'` (a compile failure is this cycle's red).

- [ ] **Step 4: Implement the field and helper**

In `Modelo/Models/Server.swift`, after the `connectionID` property (line 32), add:

```swift
    /// When false the server is fully dormant: hidden from the chat and menu-bar
    /// pickers and skipped by every background monitor (reachability, model
    /// discovery, GPU/Prometheus metrics). Settings still lists it so it can be
    /// probed and re-enabled. Defaults to true so existing rows migrate unchanged.
    var isEnabled: Bool = true
```

After the `contextLength(for:)` method (line 44), add:

```swift
    /// One server's component of ContentView's `serverDiscoveryKey`. Any field
    /// change that should re-run model discovery and restart the monitors must
    /// appear here — including `isEnabled`, which is what makes the Settings
    /// toggle take effect without an app relaunch.
    func discoverySignature(isOnline: Bool) -> String {
        "\(id)|\(host)|\(port)|\(kindRaw)|\(isOnline)|\(metricsAgentURL ?? "")|\(prometheusURL ?? "")|\(localGPU)|\(isEnabled)"
    }
```

(`prometheusURL` joins the signature because Task 2 starts restarting `PrometheusMonitor` on this key; without it, editing that URL wouldn't restart the scrape.)

Do NOT add an `isEnabled` parameter to `init` — the default is always correct at creation; the toggle is flipped later in Settings (YAGNI).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test -only-testing:ModeloTests/ServerRegistryTests`

Expected: **TEST SUCCEEDED**, including the two new tests.

- [ ] **Step 6: Commit**

```bash
git add Modelo/Models/Server.swift ModeloTests/ServerRegistryTests.swift
git commit -m "feat(model): Server.isEnabled + discovery signature

A disabled server should be fully dormant, so the flag lives on the model
(one source of truth) and joins the discovery signature so toggling takes
effect without a relaunch.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Enforce dormancy at the seams

**Files:**
- Modify: `Modelo/ModeloApp.swift:247-253` (`startMonitoring`)
- Modify: `Modelo/ContentView.swift:49-52` (environment), `:158-164` (discovery task), `:429-434` (`serverDiscoveryKey`), `:482-512` (`refreshModels`)
- Modify: `Modelo/Views/MenuBarChatView.swift:293-295` (`fetchModels`)
- Modify: `Modelo/Views/StatusView.swift:24-76` (grid, live count, refresh)

**Interfaces:**
- Consumes: `Server.isEnabled: Bool`, `Server.discoverySignature(isOnline: Bool) -> String` (Task 1).
- Produces: nothing new for later tasks — Task 3 only binds `$server.isEnabled`.

- [ ] **Step 1: Filter the launch-time monitor start (`ModeloApp.swift`)**

Replace the fetch line in `startMonitoring` (line 248):

```swift
    @MainActor private func startMonitoring() async {
        let servers = ((try? ModelContext(container).fetch(FetchDescriptor<Server>())) ?? [])
            .filter(\.isEnabled)   // disabled servers are dormant: never polled
        reachabilityMonitor.start(servers: servers)
        serverMonitor.start(servers: servers, registry: registry)
        gpuMonitor.start(servers: servers)
        prometheusMonitor.start(servers: servers)
    }
```

- [ ] **Step 2: Restart all four monitors on toggle and filter discovery (`ContentView.swift`)**

Add two environment properties next to the existing ones (lines 49-51):

```swift
    @Environment(ReachabilityMonitor.self) private var reachabilityMonitor
    @Environment(PrometheusMonitor.self) private var prometheusMonitor
```

(Both are already injected app-wide — `StatusView` reads them from the environment today.)

Replace the `.task(id: serverDiscoveryKey)` block (lines 158-164):

```swift
        .task(id: serverDiscoveryKey) {
            let enabled = servers.filter(\.isEnabled)
            gpuMonitor.start(servers: enabled)   // pick up agent-URL / macmon changes
            // Restart load-state polling too, so switching a server to exo (or adding one)
            // at runtime begins populating its loaded-model snapshot without an app relaunch.
            monitor.start(servers: enabled, registry: registry)
            // Reachability + Prometheus used to start only at launch; restarting them
            // here is what makes a Settings isEnabled toggle stop their polling live.
            reachabilityMonitor.start(servers: enabled)
            prometheusMonitor.start(servers: enabled)
            await refreshModels()
            // The launcher's transient selection can't point at a dormant server.
            if pickedModel?.server.isEnabled == false { pickedModel = nil }
        }
```

Replace `serverDiscoveryKey` (lines 429-434) to use the Task 1 helper (keeping the doc comment, now also covering the toggle):

```swift
    /// Re-discover when a server is added/edited/removed, comes online, or is
    /// enabled/disabled — not just when the online set changes — so a
    /// newly-configured server's models appear and a disabled server's vanish.
    private var serverDiscoveryKey: String {
        servers.map { $0.discoverySignature(isOnline: registry.isOnline($0)) }
            .joined(separator: ",")
    }
```

In `refreshModels()` (line 487), filter the targets:

```swift
        // Query every enabled server, not just ones the reachability monitor has
        // already flagged online — a freshly-added/edited server (or one that came
        // up after launch) is "unknown" until its next probe, and we shouldn't hide
        // its models in the meantime. fetchModels fails fast for genuinely-offline
        // servers. Disabled servers are dormant and never queried.
        let targets = servers.filter(\.isEnabled)
            .map { (server: $0, endpoint: Endpoint(server: $0, keychain: keychain)) }
```

- [ ] **Step 3: Filter the menu-bar discovery (`MenuBarChatView.swift`)**

Replace lines 294-295 in `fetchModels()`:

```swift
        let targets = servers.filter { $0.isEnabled && registry.isOnline($0) }
            .map { (server: $0, endpoint: Endpoint(server: $0, keychain: keychain)) }
```

- [ ] **Step 4: Filter the status dashboard (`StatusView.swift`)**

Below the `@Query` (line 24), replace the `liveCount` property (line 26) with:

```swift
    /// Disabled servers are parked — not polled, so not shown on the dashboard.
    private var visibleServers: [Server] { servers.filter(\.isEnabled) }

    private var liveCount: Int { visibleServers.filter { registry.isOnline($0) }.count }
```

Then swap `servers` → `visibleServers` in three places:
- the grid: `ForEach(visibleServers) { server in` (line 35)
- the header count: `Text("\(liveCount) of \(visibleServers.count) live")` (line 60)
- the refresh button loop: `for server in visibleServers {` (line 65)

- [ ] **Step 5: Build and run the full test suite**

Run the Global Constraints build command, then the test command (full suite, no `-only-testing`).
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Modelo/ModeloApp.swift Modelo/ContentView.swift Modelo/Views/MenuBarChatView.swift Modelo/Views/StatusView.swift
git commit -m "feat: disabled servers go fully dormant

Filter at the seams where server lists enter each subsystem (monitor
starts, discovery, menu bar, status board) instead of inside the services,
and restart reachability/Prometheus on the discovery key so the toggle
takes effect without a relaunch.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Settings toggle UI

**Files:**
- Modify: `Modelo/Settings/SettingsView.swift` — `ServerSettingsRow` (lines 798-912) and `CloudServerSettingsRow` (lines 1295-1401)

**Interfaces:**
- Consumes: `Server.isEnabled` via the rows' existing `@Bindable var server: Server`.
- Produces: nothing — terminal UI task.

- [ ] **Step 1: Add the toggle to `ServerSettingsRow`'s header**

In the header `HStack` (line 818), insert between `Spacer(minLength: 8)` (line 828) and `runtimePicker` (line 829):

```swift
                Toggle("", isOn: $server.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(server.isEnabled
                          ? "Disable server — hides it from pickers and stops all polling"
                          : "Enable server")
```

Dim the identity block when disabled — add `.opacity(server.isEnabled ? 1 : 0.45)` to both the `StatusLED` (line 819) and the label `VStack` (lines 820-827).

Dim and lock the expanded detail — on the `VStack(alignment: .leading, spacing: 14)` inside `if isExpanded` (line 848), add after its existing modifiers:

```swift
                .opacity(server.isEnabled ? 1 : 0.5)
                .disabled(!server.isEnabled)
```

(Header controls — toggle, delete, expand — stay live. `ServerProbeRow` is non-interactive, so `.disabled` doesn't stop its probe: a parked machine can still be checked before re-enabling, per the spec.)

- [ ] **Step 2: Same treatment for `CloudServerSettingsRow`**

In its header `HStack` (line 1313), insert the identical `Toggle` block between `Spacer(minLength: 8)` (line 1325) and `Chip(...)` (line 1326), with help text "Disable endpoint — hides it from pickers and stops all polling" / "Enable endpoint".

Add `.opacity(server.isEnabled ? 1 : 0.45)` to the `StatusLED` (line 1314) and label `VStack` (lines 1315-1324).

On the detail `VStack` inside `if isExpanded` (line 1345), add `.opacity(server.isEnabled ? 1 : 0.5)` and `.disabled(!server.isEnabled)` after the existing `.transition(...)` modifier.

- [ ] **Step 3: Build and run the full test suite**

Run the Global Constraints build command, then the test command.
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual smoke test**

Launch the Debug build (`open build/Build/Products/Debug/Modelo.app`) and verify:

1. Settings → each server row shows the switch; flipping it does NOT expand/collapse the row (the row header has an `onTapGesture` — the delete `Button` already coexists with it, so the `Toggle` should too; if the tap gesture swallows the toggle, report back rather than improvising).
2. Toggle a server off → its pill and models leave the chat picker and the Status board without relaunch; "N of M live" shrinks by one in M.
3. Toggle it back on → models and status card return within one refresh cycle.
4. A chat bound to the disabled server keeps its history and simply can't send (existing missing-server behavior — no crash, no new UI).
5. Quit and relaunch → the off state persisted; the disabled server is not probed (its Settings row LED may still update while Settings is open — that's by design).

- [ ] **Step 5: Commit**

```bash
git add Modelo/Settings/SettingsView.swift
git commit -m "feat(settings): per-server enable switch

Prominent in the row header (flipped routinely for machines that are
usually off); disabled rows dim and lock their detail controls but keep
probe/delete so a parked server can be checked and re-enabled.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Done criteria

All three tasks committed on `feature/server-enabled-toggle`; full test suite green; manual smoke checklist passed. Then stop for human review (schema + UI change per AGENTS.md) — the user decides on merge.
