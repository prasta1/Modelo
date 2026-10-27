# Modelo for iOS — Slice 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A universal iOS app target that shares Modelo's core, opens its own SwiftData store, and lets the user add, edit, reorder, pause, and delete endpoints with live reachability status.

**Architecture:** A second XcodeGen target (`ModeloiOS`) compiles an explicit list of portable files from `Modelo/Models` and `Modelo/Services` plus a new `ModeloiOS/` folder of iOS views. Logic the iOS views need is added to *shared* files (`StoreBootstrap`, `CloudPreset`, `EndpointDraft`) so the existing macOS `ModeloTests` covers it; the iOS views stay thin.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, XcodeGen, XCTest (macOS host).

**Spec:** `docs/superpowers/specs/2026-10-27-ios-foundation-design.md`

## Global Constraints

- iOS deployment target **17.0**; `TARGETED_DEVICE_FAMILY: "1,2"` (iPhone + iPad).
- iOS bundle ID is `$(PRODUCT_BUNDLE_IDENTIFIER_BASE)` via `Signing.xcconfig` — the same as the Mac app.
- No new SPM packages; the iOS target links none in this slice.
- The `Modelo` scheme, `ModeloTests`, `scripts/install.sh`, and `.github/workflows/release.yml` keep working unchanged; Mac behavior is unchanged.
- Secrets live only in `KeychainStore` under `Endpoint.keychainAccount(for:)` — never in SwiftData (`Server.apiKey` stays unused).
- iOS does **not** call `ServerRegistry.seedIfNeeded` or `Persona.seedDefaults`.
- Inherently Mac-only files (`GPUMonitor`, `MCPClient`, `FilesystemTools`, `SessionSnapshot`, `ProjectStore`) are excluded from the iOS target, never `#if`-guarded into it.
- Run `xcodegen generate` after every `project.yml` change.
- **Every task ends with both gates green** (the "Gates" commands below). A `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **` line is the only acceptable evidence.
- All work happens in the worktree `.worktrees/ios` on `feature/ios`; never switch the main checkout's branch.

**Gates:**

```bash
# Mac: build + full suite
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
# iOS: build
xcodebuild -project Modelo.xcodeproj -scheme ModeloiOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Review Focus

1. **Adding an API key to a "NO KEY" server** — the row should go live right away, not up to 30 s later. Task 6 saves then calls `reachability.checkOnce(server)`.
2. **Adding, removing, pausing, or re-pointing a server at runtime** — the probe set must restart (the Mac shipped this bug once: paused servers were probed forever). Task 5 keys `.task(id:)` on id + `isPaused` + `host` + `port` + `kindRaw`.
3. **Host pasted as `http://spark/`, `  spark `, or `https://box.ts.net`** — saved as `spark` / `spark` / `https://box.ts.net`. Task 4 tests `test_save_normalizesHost` and `test_save_keepsHTTPSPrefix`.
4. **Deleting a cloud endpoint** — its key must not linger in the keychain. Task 4 tests `test_delete_removesServerAndKeychainSecret`.
5. **Local Network permission denied / host unreachable** — rows read OFFLINE and Test connection reports failure; nothing hangs or crashes. Manual check in Task 7 (the probe already times out at 4 s).

---

## File Map

| File | Change | Task |
|---|---|---|
| `project.yml` | Add `ModeloiOS` target + scheme | 1 |
| `ModeloiOS/ModeloiOSApp.swift` | Create — `@main`, container, monitors, recovery alert | 1, 2, 5 |
| `ModeloiOS/ModeloiOS.entitlements` | Create — keychain access group | 1 |
| `ModeloiOS/Assets.xcassets/AppIcon.appiconset/` | Create — single 1024 icon copied from the Mac set | 1 |
| `Modelo/Services/ReachabilityMonitor.swift` | `#if os` the activation notifications | 1 |
| `Modelo/Services/StoreBootstrap.swift` | Create — schema + `makeContainer` moved from `ModeloApp` | 2 |
| `Modelo/ModeloApp.swift` | Call `StoreBootstrap` | 2 |
| `ModeloTests/StoreRecoveryTests.swift` | Point at `StoreBootstrap` | 2 |
| `Modelo/Services/CloudPreset.swift` | Create — preset list moved from `SettingsView` | 3 |
| `Modelo/Settings/SettingsView.swift` | Use `CloudPreset.all` | 3 |
| `ModeloTests/CloudPresetTests.swift` | Create | 3 |
| `Modelo/Models/Server.swift` | Extract static `baseURL(kind:host:port:)` | 4 |
| `Modelo/Services/EndpointDraft.swift` | Create — form state, validation, save, delete, reorder | 4 |
| `ModeloTests/EndpointDraftTests.swift` | Create | 4 |
| `ModeloiOS/RootView.swift` | Create — split view shell, reachability wiring | 5 |
| `ModeloiOS/EndpointsView.swift` | Create — list, rows, add menu, delete, reorder, pause | 5 |
| `ModeloiOS/EndpointFormView.swift` | Create — add/edit form, Test connection | 6 |

---

### Task 1: iOS target compiles the shared core

**Files:**
- Modify: `project.yml`, `Modelo/Services/ReachabilityMonitor.swift:1,95-105`
- Create: `ModeloiOS/ModeloiOSApp.swift`, `ModeloiOS/ModeloiOS.entitlements`, `ModeloiOS/Assets.xcassets/{Contents.json,AppIcon.appiconset/Contents.json,AppIcon.appiconset/icon_1024x1024.png}`

**Interfaces:**
- Produces: scheme `ModeloiOS`; struct `ModeloiOSApp: App` (placeholder body `WindowGroup { Text("Modelo") }`); the iOS-compilable shared source list.

- [ ] **Step 1: Add the target to `project.yml`**

Add `deploymentTarget: iOS: "17.0"` under `options`. New target, values exactly:

```yaml
  ModeloiOS:
    type: application
    platform: iOS
    sources:
      - ModeloiOS
      - Modelo/Models
      - Modelo/Services/Endpoint.swift
      - Modelo/Services/ServerRegistry.swift
      - Modelo/Services/KeychainStore.swift
      - Modelo/Services/Log.swift
      - Modelo/Services/ReachabilityMonitor.swift
      - Modelo/Services/PollingLoop.swift
      - Modelo/Services/LMStudioClient.swift
      # + transitive dependencies found in Step 4
    info:
      path: ModeloiOS/Info.plist
      properties:
        CFBundleDisplayName: Modelo
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        UILaunchScreen: {}
        UIApplicationSupportsIndirectInputEvents: true
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait, UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]
        UISupportedInterfaceOrientations~ipad: [UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown, UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSLocalNetworkUsageDescription: "Modelo connects to model servers on your local network and Tailscale."
    configFiles:
      Debug: Signing.xcconfig
      Release: Signing.xcconfig
    settings:
      base:
        PRODUCT_NAME: Modelo
        PRODUCT_MODULE_NAME: ModeloiOS
        MARKETING_VERSION: "0.3.1"
        CURRENT_PROJECT_VERSION: "3"
        TARGETED_DEVICE_FAMILY: "1,2"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        CODE_SIGN_ENTITLEMENTS: ModeloiOS/ModeloiOS.entitlements
        SWIFT_VERSION: "5.0"
```

Comment the ATS and local-network keys with the same "why" as the Mac target's. Add scheme `ModeloiOS` building only `ModeloiOS`. `ModeloiOS/Info.plist` is generated by XcodeGen — add it to `.gitignore` beside `Modelo/Info.plist` (line 11).

- [ ] **Step 2: Create the entitlements, asset catalog, and placeholder app**

Entitlements: `keychain-access-groups` = `[$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)]`, with a comment pointing at `Modelo/Modelo.entitlements` for the rationale. AppIcon: single-size iOS set (`"idiom": "universal", "platform": "ios", "size": "1024x1024"`) using a copy of `Modelo/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png`.

- [ ] **Step 3: Guard `ReachabilityMonitor`'s activation hook**

Replace `import AppKit` with `#if os(macOS) import AppKit #else import UIKit #endif`; in `observeAppActivation()` use `NSApplication.didBecomeActiveNotification` / `didResignActiveNotification` on macOS and `UIApplication.didBecomeActiveNotification` / `willResignActiveNotification` on iOS. No other change.

- [ ] **Step 4: Iterate the iOS build until green**

Run `xcodegen generate`, then the iOS gate. For each "cannot find X in scope", add the file defining X to the iOS `sources` list. If a needed file uses AppKit, guard only the offending lines with `#if os(macOS)`. **Stop and report** if the closure pulls in any excluded Mac-only file, or if more than 5 shared files need guards — that means the approach needs revisiting, not more guards.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the Mac gate**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add project.yml .gitignore ModeloiOS Modelo/Services/ReachabilityMonitor.swift [+ any guarded files]
git commit -m "feat(ios): add ModeloiOS target compiling the shared core"
```

---

### Task 2: Shared `StoreBootstrap`; iOS opens its store

**Files:**
- Create: `Modelo/Services/StoreBootstrap.swift`
- Modify: `Modelo/ModeloApp.swift:48,71,214-252`, `ModeloTests/StoreRecoveryTests.swift`, `ModeloiOS/ModeloiOSApp.swift`, `project.yml` (add `StoreBootstrap.swift` to iOS sources)

**Interfaces:**
- Produces:
  - `enum StoreBootstrap`
  - `static var schema: Schema` — `Server, Conversation, Message, UsageRecord, Persona, Folder, Preset`, in that order
  - `static var storeFolder: URL` — `URL.applicationSupportDirectory/Modelo/` (created if missing)
  - `static var storeURL: URL` — `storeFolder/Modelo.store`
  - `static func makeContainer(schema: Schema, storeFolder: URL, storeURL: URL) -> (ModelContainer, backupURL: URL?)` — body moved verbatim from `ModeloApp.makeContainer`, doc comment included.

- [ ] **Step 1: Point `StoreRecoveryTests` at `StoreBootstrap`**

Replace `ModeloApp.makeContainer` with `StoreBootstrap.makeContainer` (both tests and the type doc comment) and the local `schema` property's body with `StoreBootstrap.schema`.

- [ ] **Step 2: Run it to verify it fails**

Run: Mac gate with `-only-testing:ModeloTests/StoreRecoveryTests`. Expected: build failure, "cannot find 'StoreBootstrap' in scope".

- [ ] **Step 3: Create `StoreBootstrap`; make `ModeloApp` use it**

`ModeloApp.init` uses `StoreBootstrap.schema`, `.storeFolder`, `.storeURL`, `.makeContainer`; the ModeloDos migration stays in `ModeloApp` (it runs before `makeContainer`). Delete `ModeloApp.makeContainer`.

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: iOS app opens the container**

`ModeloiOSApp.init` calls `StoreBootstrap.makeContainer(schema: .schema, storeFolder: .storeFolder, storeURL: .storeURL)`, applies `.modelContainer(container)` to the `WindowGroup`, and shows the same alert as the Mac — title "Chat database was reset", the same message text with the backup path — when `backupURL != nil`.

- [ ] **Step 6: Both gates, then commit**

```bash
git add Modelo/Services/StoreBootstrap.swift Modelo/ModeloApp.swift ModeloTests/StoreRecoveryTests.swift ModeloiOS/ModeloiOSApp.swift project.yml
git commit -m "refactor: share store bootstrap so iOS opens the store with the same recovery"
```

---

### Task 3: Shared `CloudPreset`

**Files:**
- Create: `Modelo/Services/CloudPreset.swift`, `ModeloTests/CloudPresetTests.swift`
- Modify: `Modelo/Settings/SettingsView.swift:26-38,114-116`, `project.yml` (iOS sources)

**Interfaces:**
- Produces: `struct CloudPreset: Identifiable, Sendable { var id: String { name }; let name: String; let baseURL: String; static let all: [CloudPreset] }` — the six entries moved verbatim, same order (OpenAI, Groq, OpenRouter, Together, DeepSeek, Mistral).

- [ ] **Step 1: Write the failing test**

```swift
func test_all_haveNamesAndHTTPSBaseURLs() {
    XCTAssertEqual(CloudPreset.all.count, 6)
    for p in CloudPreset.all {
        XCTAssertFalse(p.name.isEmpty)
        let url = try XCTUnwrap(URL(string: p.baseURL), p.name)
        XCTAssertEqual(url.scheme, "https", p.name)
        XCTAssertNotNil(url.host(), p.name)
    }
}
func test_ids_areUnique() {
    XCTAssertEqual(Set(CloudPreset.all.map(\.id)).count, CloudPreset.all.count)
}
```
(Make the first test `throws`.)

- [ ] **Step 2: Run to verify it fails** — `-only-testing:ModeloTests/CloudPresetTests`; expected "cannot find 'CloudPreset'".
- [ ] **Step 3: Create `CloudPreset`; delete the private copy in `SettingsView`; its menu iterates `CloudPreset.all`.**
- [ ] **Step 4: Run to verify it passes**, then both gates.
- [ ] **Step 5: Commit** — `git commit -m "refactor: share cloud presets between Mac and iOS"` (stage the four files).

---

### Task 4: `EndpointDraft` — form state, validation, save, delete, reorder

**Files:**
- Modify: `Modelo/Models/Server.swift:57-67`
- Create: `Modelo/Services/EndpointDraft.swift`, `ModeloTests/EndpointDraftTests.swift`
- Modify: `project.yml` (iOS sources)

**Interfaces:**
- Consumes: `CloudPreset` (Task 3), `Endpoint`, `KeychainStore`, `Server.normalizedHost`, `ModelContext.saveOrLog()`.
- Produces:
  - `extension Server { static func baseURL(kind: ServerKind, host: String, port: Int) -> String }` — the existing instance `baseURL` switch moved here; instance property becomes `Server.baseURL(kind: kind, host: host, port: port)`.
  - `struct EndpointDraft: Equatable`:
    - `var kind: ServerKind`, `var label: String`, `var host: String`, `var port: Int`, `var connectionID: String`, `var apiKey: String`
    - `init(kind: ServerKind)`: label `kind.displayName`; host `""`; port `kind.defaultPort`; others `""`. For `.cloudAPI`, label `"Cloud API"`.
    - `init(preset: CloudPreset)`: kind `.cloudAPI`, label `preset.name`, host `preset.baseURL`, port `0`.
    - `init(server: Server, keychain: KeychainStore)`: copies the fields; `apiKey` from `keychain.get(account: Endpoint.keychainAccount(for:))` or `""`.
    - `mutating func switchRuntime(to: ServerKind)`: sets kind; re-seeds `port` to `to.defaultPort` only if `ServerKind.isDefaultLocalPort(port)`; if label equals the old kind's `displayName`, it becomes the new one's.
    - `var isValid: Bool`: trimmed label non-empty, **and** local kinds have a non-empty host after `normalizedHost` with the `https://` prefix removed, and `1...65535 ~= port`; `.cloudAPI` needs a trimmed host that parses as a URL with an `http`/`https` scheme and a non-nil host; `.openRouter`/`.nous` need nothing more.
    - `var endpoint: Endpoint`: `Endpoint(baseURL: Server.baseURL(kind:host: normalizedHost-or-trimmed,port:), kind:, apiKey: trimmed key or nil when empty)`.
    - `@discardableResult func save(into context: ModelContext, keychain: KeychainStore, existing: Server?) -> Server`: on insert, `sortOrder = (max existing sortOrder ?? 0) + 1` (the Mac's rule). Writes trimmed label, `kindRaw`, `connectionID`; host = `Server.normalizedHost(host)` for local, trimmed for `.cloudAPI`, `""` for fixed-URL kinds; port = `port` for local, `0` for cloud. For non-local kinds, `keychain.set(trimmedKey.isEmpty ? nil : trimmedKey, account: Endpoint.keychainAccount(for: server))`; never touches `server.apiKey`. Ends with `context.saveOrLog()`.
  - `enum ServerListActions`:
    - `static func delete(_ server: Server, in context: ModelContext, keychain: KeychainStore)`: clears the keychain account, deletes, saves.
    - `static func reorder(_ servers: [Server], fromOffsets: IndexSet, toOffset: Int)`: applies `move(fromOffsets:toOffset:)` to a copy, then sets `sortOrder = index` (0-based, contiguous). The caller saves.

- [ ] **Step 1: Write the failing tests** in `EndpointDraftTests` (in-memory `ModelContainer(for: StoreBootstrap.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`; per-test `KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")` as in `KeychainStoreTests`):

| Test | Assertion |
|---|---|
| `test_newLocal_prefillsDefaults` | `EndpointDraft(kind: .ollama)` → port `11434`, label `"Ollama"`, host `""` |
| `test_switchRuntime_reseedsDefaultPortAndLabel` | `.lmStudio` (1234, "LM Studio") → `.ollama` → `11434`, `"Ollama"` |
| `test_switchRuntime_keepsCustomPortAndLabel` | port `9999`, label `"Spark"` → `.ollama` → `9999`, `"Spark"` |
| `test_isValid_local` | host `"  "` false; `"http://"` false; `"https://"` false; `"spark"` + `1234` true; port `0` false; `70000` false; label `" "` false |
| `test_isValid_customCloud` | `"api.example.com"` false; `"https://api.example.com/v1"` true |
| `test_isValid_fixedURLKinds` | `.openRouter` and `.nous` with host `""` → true |
| `test_save_insertsWithNextSortOrder` | existing server `sortOrder 3` → saved draft `sortOrder 4`; empty store → `1` |
| `test_save_normalizesHost` | `"http://spark/"` → `"spark"`; `"  spark "` → `"spark"` |
| `test_save_keepsHTTPSPrefix` | `"https://box.ts.net"` → `"https://box.ts.net"` |
| `test_save_cloud_storesTrimmedKeyInKeychainOnly` | key `"  sk-1 "` → `keychain.get(account:) == "sk-1"`; `server.apiKey == nil` |
| `test_save_cloud_emptyKeyClearsKeychain` | key preset to `"old"`, save with `""` → `get == nil` |
| `test_save_existing_updatesInPlace` | edit and save an existing server → fetch count unchanged, label updated |
| `test_initFromServer_roundTrips` | save a cloud draft, then `EndpointDraft(server:keychain:)` equals the saved values (trimmed) |
| `test_endpoint_usesNormalizedBaseURL` | `.lmStudio`, host `"http://spark"`, port 1234 → `endpoint.baseURL == "http://spark:1234"`, `apiKey == nil` |
| `test_delete_removesServerAndKeychainSecret` | after delete: fetch count 0; `keychain.get == nil` |
| `test_reorder_rewritesSortOrderContiguously` | servers A,B,C at sortOrder 5,9,12; move C to 0 → C=0, A=1, B=2 |

- [ ] **Step 2: Run to verify they fail** — `-only-testing:ModeloTests/EndpointDraftTests`; expected "cannot find 'EndpointDraft'".
- [ ] **Step 3: Extract `Server.baseURL(kind:host:port:)`; run `-only-testing:ModeloTests/EndpointTests`** — expected pass (pure refactor).
- [ ] **Step 4: Implement `EndpointDraft` and `ServerListActions`** (`import SwiftUI` for `move(fromOffsets:toOffset:)`).
- [ ] **Step 5: Run to verify they pass**, then both gates.
- [ ] **Step 6: Commit** — `git commit -m "feat: EndpointDraft for validated endpoint add/edit, shared for iOS"` (stage the four files).

---

### Task 5: iOS shell and endpoints list with live status

**Files:**
- Create: `ModeloiOS/RootView.swift`, `ModeloiOS/EndpointsView.swift`
- Modify: `ModeloiOS/ModeloiOSApp.swift`

**Interfaces:**
- Consumes: `ServerRegistry`, `ReachabilityMonitor`, `LMStudioClient.shared.probeReachable(endpoint:)`, `ServerListActions` (Task 4), `ServerStatus.displayLabel`.
- Produces: `struct RootView: View`, `struct EndpointsView: View`. `EndpointsView` presents `EndpointFormView(draft: EndpointDraft, existing: Server?)` (Task 6). Until Task 6 lands, use a stub `EndpointFormView` that only has that initializer; Task 6 replaces it.

- [ ] **Step 1: App wiring**

`ModeloiOSApp` owns `ServerRegistry()` and `ReachabilityMonitor(registry:) { await LMStudioClient.shared.probeReachable(endpoint: $0) }` (the Mac's closure), injects both with `.environment`, and shows `RootView()`.

- [ ] **Step 2: `RootView`**

- `NavigationSplitView`. Sidebar: `ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")`, title "Modelo", and a toolbar gear (`gearshape`) that presents a sheet with `NavigationStack { EndpointsView() }` titled "Settings". Detail: an empty placeholder.
- `@Query(sort: \Server.sortOrder) var servers`.
- `.task(id: probeKey) { reachability.start(servers: servers.filter { !$0.isPaused }) }`, where `probeKey` is `servers.map { "\($0.id)|\($0.isPaused)|\($0.host)|\($0.port)|\($0.kindRaw)" }`. This is Review Focus #2.

- [ ] **Step 3: `EndpointsView`**

- A `List` of rows over `@Query(sort: \Server.sortOrder)`. Each row shows label, `kind.displayName`, host (or base URL for cloud), a status dot plus `displayLabel` (green online, red offline, orange needsKey, gray unknown), latency as `"%.0f ms"` when present, and a `Toggle` bound to `isPaused` (save on change).
- Tapping a row presents the form sheet with `EndpointDraft(server:keychain:)` and `existing: server`.
- `.onMove` → `ServerListActions.reorder`, then `saveOrLog()`. `EditButton` in the toolbar.
- `.onDelete` → a `confirmationDialog` "Delete \"<label>\"? Its API key is removed too." → `ServerListActions.delete`.
- Toolbar "+" `Menu` with sections:
  - "Local": `ServerKind.localCases` → `EndpointDraft(kind:)`.
  - "Cloud": `.openRouter`, `.nous`, then `CloudPreset.all` → `EndpointDraft(preset:)`, then "Custom…" → `EndpointDraft(kind: .cloudAPI)`.
  - Each choice presents the form with `existing: nil`.
- Empty state: `ContentUnavailableView("Add an endpoint", systemImage: "server.rack", description: Text("Connect to LM Studio, Ollama, or a cloud API."))`.

- [ ] **Step 4: Both gates, then commit**

```bash
git add ModeloiOS/RootView.swift ModeloiOS/EndpointsView.swift ModeloiOS/EndpointFormView.swift ModeloiOS/ModeloiOSApp.swift
git commit -m "feat(ios): split-view shell and endpoints list with live reachability"
```

---

### Task 6: Endpoint add/edit form

**Files:**
- Modify (replace stub): `ModeloiOS/EndpointFormView.swift`

**Interfaces:**
- Consumes: `EndpointDraft` (Task 4), `ReachabilityMonitor.checkOnce(_:)`, `LMStudioClient.shared.probeReachable(endpoint:)`.
- Produces: `struct EndpointFormView: View { init(draft: EndpointDraft, existing: Server?) }`.

- [ ] **Step 1: Build the form**

- A `NavigationStack` around a `Form` bound to `@State var draft`. Title: "New Endpoint", or the label when editing.
- **Local kinds:** a runtime `Picker` over `ServerKind.localCases` that calls `draft.switchRuntime(to:)`; a Label field; a Host field (`.keyboardType(.URL)`, no autocapitalization or autocorrection); a Port field (`TextField(value:format: .number.grouping(.never))`, `.numberPad`); and a "Subtitle" field for `connectionID`.
- **Cloud kinds:** a Label field; a Base URL field (hidden when `kind.hasFixedURL`); and an API key `SecureField`.
- A **Test connection** section: a button that runs `await LMStudioClient.shared.probeReachable(endpoint: draft.endpoint)` with a `ProgressView` while it runs, then shows "Reachable" (green) or "Not reachable" (red) inline. Disabled while `!draft.isValid`.
- Toolbar: Cancel dismisses with no write. Save is disabled while `!draft.isValid` and runs `let server = draft.save(into: context, keychain: KeychainStore(), existing: existing)`, then `Task { await reachability.checkOnce(server) }` (Review Focus #1), then dismisses.

- [ ] **Step 2: Both gates, then commit**

```bash
git add ModeloiOS/EndpointFormView.swift
git commit -m "feat(ios): endpoint add/edit form with test connection"
```

---

### Task 7: Verify on device and hand off

- [ ] **Step 1: Run both gates from a clean `build/`** (`rm -rf build` first). Expect `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Hand Patrick the manual checklist**

Open `.worktrees/ios/Modelo.xcodeproj` in Xcode, select the `ModeloiOS` scheme and an iPhone, and Run. Then:
1. Add LM Studio by Tailscale hostname → the Local Network prompt appears; the row goes LIVE with a latency.
2. Deny Local Network in iOS Settings → the row reads OFFLINE and Test connection says "Not reachable" within ~4 s (Review Focus #5).
3. Add OpenRouter with no key → NO KEY. Add a key → LIVE without waiting. Delete and reinstall the app → the key persists.
4. Pause a server, background the app, return, unpause → polling stops and resumes.
5. Delete a cloud endpoint → it's gone; re-adding the same preset shows an empty key field.
6. On iPad → the sidebar is visible and Settings opens as a sheet.
- [ ] **Step 3: Record results.** Fix failures as follow-up tasks on this branch. Merge only after Patrick confirms.
