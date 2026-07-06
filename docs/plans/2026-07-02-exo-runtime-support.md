# exo Runtime Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exo as a first-class local runtime in Modelo that lists only the models actually present on the exo machine (not exo's full HuggingFace catalog), with optional native load/unload via exo's instance API.

**Architecture:** exo is added as a new `ServerKind.exo` case, addressed by host:port (default 52415), OpenAI-compatible for chat. Its only fetch difference is using `/v1/models?status=downloaded`. Because every `switch` over `ServerKind` is exhaustive, the compiler enumerates all touchpoints. Tier 2 adds a dedicated `ExoClient` for exo's camelCase `/state` + place/unplace instance endpoints.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData, XcodeGen (`project.yml`), XCTest (`@testable import Modelo`, `StubURLProtocol` for HTTP mocking).

**Spec:** `docs/specs/2026-07-02-exo-runtime-support.md`

**Decisions locked (2026-07-02):** dedicated `ExoClient` for Tier 2; explicit "Load" action with a RAM-cost confirmation (no auto-place-on-select); the "launch model in exo first" hint ships in Tier 1.

---

## How to run tests

Full suite:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

A single test class/case (faster iteration) — append `-only-testing:`:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:ModeloTests/EndpointTests CODE_SIGNING_ALLOWED=NO test
```

> Note: if `project.yml` changes, regenerate the project first: `xcodegen generate`. This plan adds files to existing targets, so run `xcodegen generate` after creating any new `.swift` file (Task 3) so it's included in the build.

---

## File Structure

**Tier 1 (modify only — no new files):**
- `Modelo/Services/Endpoint.swift` — `ServerKind.exo` case + `isLocal`/`displayName`/`defaultPort`.
- `Modelo/Models/Server.swift` — `baseURL` (host:port for exo).
- `Modelo/Services/LMStudioClient.swift` — `fetchModels`, two path helpers, chat path.
- `Modelo/Services/ReachabilityMonitor.swift` — poll interval.
- `Modelo/Settings/SettingsView.swift` — runtime icon + connection hint.
- `Modelo/Views/ServerRow.swift` — sidebar subtitle.
- `Modelo/Views/ServerStatsView.swift` — status host label.
- `ModeloTests/EndpointTests.swift` — extend enum tests.
- `ModeloTests/LMStudioClientTests.swift` — exo fetch tests.

**Tier 2 (new files + modify):**
- `Modelo/Services/ExoClient.swift` — **new.** exo `/state` decode + place/delete instance.
- `Modelo/Services/ServerMonitor.swift` — dispatch exo load-state through `ExoClient`.
- `Modelo/Settings/SettingsView.swift` (or the model-picker row view) — Load/Unload wiring for exo.
- `ModeloTests/ExoClientTests.swift` — **new.** decode + request-construction tests.

---

# TIER 1 — First-class exo endpoint

## Task 1: Add `.exo` as a local runtime (generic OpenAI-compatible), green build

Adding the enum case breaks every exhaustive `switch` until handled. This task adds the case and all switch arms so exo behaves like a generic local kind (plain `/v1/models`). Task 2 changes the fetch to the downloaded-only filter.

**Files:**
- Modify: `Modelo/Services/Endpoint.swift`
- Modify: `Modelo/Models/Server.swift`
- Modify: `Modelo/Services/LMStudioClient.swift`
- Modify: `Modelo/Services/ReachabilityMonitor.swift`
- Modify: `Modelo/Settings/SettingsView.swift`
- Modify: `Modelo/Views/ServerRow.swift`
- Modify: `Modelo/Views/ServerStatsView.swift`
- Test: `ModeloTests/EndpointTests.swift`

- [ ] **Step 1: Write/adjust the failing enum tests**

In `ModeloTests/EndpointTests.swift`, update the existing `localCases` test (adding `.exo` changes its expected value) and add exo assertions:

```swift
func test_serverKind_localCases_areTheLocalRuntimes() {
    XCTAssertEqual(ServerKind.localCases, [.lmStudio, .llamaCpp, .oMLX, .ollama, .exo])
    XCTAssertTrue(ServerKind.oMLX.isLocal)
    XCTAssertTrue(ServerKind.exo.isLocal)
    XCTAssertFalse(ServerKind.cloudAPI.isLocal)
}

func test_serverKind_exo_defaultsAndLabel() {
    XCTAssertEqual(ServerKind.exo.rawValue, "exo")
    XCTAssertEqual(ServerKind.exo.displayName, "exo")
    XCTAssertEqual(ServerKind.exo.defaultPort, 52415)
    XCTAssertTrue(ServerKind.isDefaultLocalPort(52415))
}

func test_baseURL_exo_usesHostPort() {
    let s = Server(label: "exo", host: "localhost", port: 52415, kind: .exo)
    XCTAssertEqual(s.baseURL, "http://localhost:52415")
}
```

- [ ] **Step 2: Run tests to verify they fail (build error)**

Run:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ModeloTests/EndpointTests CODE_SIGNING_ALLOWED=NO test
```

Expected: **BUILD FAILED** — `type 'ServerKind' has no member 'exo'`.

- [ ] **Step 3: Add the enum case + core properties**

In `Modelo/Services/Endpoint.swift`, add the case after `ollama`:

```swift
    /// Local Ollama runtime — OpenAI-compatible /v1, default port 11434.
    case ollama
    /// Local exo cluster runtime — OpenAI-compatible /v1, default port 52415.
    /// exo's /v1/models lists its whole catalog, so model fetching uses the
    /// downloaded-only filter (see LMStudioClient.fetchModels).
    case exo
```

Update `isLocal` (add `.exo` to the local group):

```swift
        case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: true
        case .cloudAPI, .openRouter:                     false
```

Update `displayName` (add before the cloud cases):

```swift
        case .ollama:     return "Ollama"
        case .exo:        return "exo"
```

Update `defaultPort`:

```swift
        case .ollama:                return 11434
        case .exo:                   return 52415
```

- [ ] **Step 4: Fix `Server.baseURL`**

In `Modelo/Models/Server.swift`, add `.exo` to the host:port group:

```swift
        case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: "http://\(Server.normalizedHost(host)):\(port)"
```

- [ ] **Step 5: Fix `LMStudioClient` switches (generic local behavior for now)**

In `Modelo/Services/LMStudioClient.swift`:

`fetchModels` — group exo with the other generic local kinds for now:

```swift
        case .llamaCpp, .oMLX, .exo:
            // Generic local OpenAI-compatible servers (llama.cpp/llama-swap, oMLX, exo): no /api/v0.
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
```

The two `path` helper switches (~line 111 and ~line 130) — add `.exo` to the `/v1/models` arm:

```swift
        case .ollama, .exo: path = "/v1/models"
```

The chat-path switch (~line 296) — add `.exo` to the `/v1/chat/completions` arm:

```swift
        case .lmStudio, .llamaCpp, .oMLX, .exo: chatPath = "/v1/chat/completions"
```

- [ ] **Step 6: Fix `ReachabilityMonitor` poll interval**

In `Modelo/Services/ReachabilityMonitor.swift`, add `.exo` to the local group:

```swift
        case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: return status == .online ? .seconds(10) : .seconds(30)
```

- [ ] **Step 7: Fix `SettingsView` icon + hint**

In `Modelo/Settings/SettingsView.swift`, `localIcon(for:)` — add an exo icon (before the `default`):

```swift
        case .ollama:   return "cylinder"
        case .exo:      return "point.3.connected.trianglepath.dotted"
```

`hint` (exhaustive switch) — add an exo case:

```swift
        case .exo:
            return "Run exo (exolabs.net) on this or another Mac. Add its host and port (default 52415). Models must be launched in exo's dashboard before you can chat with them."
        case .cloudAPI, .openRouter:
            return ""
```

- [ ] **Step 8: Fix `ServerRow` and `ServerStatsView`**

In `Modelo/Views/ServerRow.swift`, add `.exo` to the local `host:port` group (mirror the existing `case .lmStudio, .llamaCpp, .oMLX, .ollama:` arm — add `, .exo`).

In `Modelo/Views/ServerStatsView.swift`:

```swift
        case .lmStudio, .llamaCpp, .oMLX, .ollama, .exo: return "\(server.host):\(server.port)"
```

- [ ] **Step 9: Run the enum tests — expect PASS**

Run:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ModeloTests/EndpointTests CODE_SIGNING_ALLOWED=NO test
```

Expected: **TEST SUCCEEDED**.

- [ ] **Step 10: Run the full suite to confirm nothing else broke**

Run the full-suite command from "How to run tests". Expected: all green.

- [ ] **Step 11: Commit**

```bash
git add Modelo/Services/Endpoint.swift Modelo/Models/Server.swift \
  Modelo/Services/LMStudioClient.swift Modelo/Services/ReachabilityMonitor.swift \
  Modelo/Settings/SettingsView.swift Modelo/Views/ServerRow.swift \
  Modelo/Views/ServerStatsView.swift ModeloTests/EndpointTests.swift
git commit -m "feat(servers): add exo as a local runtime kind"
```

---

## Task 2: Fetch only downloaded models for exo

exo's `/v1/models` returns its full catalog; `/v1/models?status=downloaded` returns only local models. Split exo out of the generic local arm.

**Files:**
- Modify: `Modelo/Services/LMStudioClient.swift:fetchModels`
- Test: `ModeloTests/LMStudioClientTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `ModeloTests/LMStudioClientTests.swift` (mirrors the existing `test_fetchModels_*` pattern; add an `exo()` endpoint helper next to `lmStudio()`):

```swift
private func exo(_ base: String = "http://localhost:52415") -> Endpoint {
    Endpoint(baseURL: base, kind: .exo, apiKey: nil)
}

func test_fetchModels_exo_requestsDownloadedOnly() async throws {
    let body = #"{"data":[{"id":"lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-4bit","object":"model"}]}"#
    StubURLProtocol.handler = { req in
        XCTAssertTrue(req.url!.absoluteString.contains("/v1/models"))
        XCTAssertTrue(req.url!.absoluteString.contains("status=downloaded"),
                      "exo must request the downloaded-only model list, got \(req.url!.absoluteString)")
        return (.stub(200), Data(body.utf8))
    }
    let models = try await makeClient().fetchModels(endpoint: exo())
    XCTAssertEqual(models.count, 1)
    XCTAssertEqual(models.first?.id, "lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-4bit")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ModeloTests/LMStudioClientTests/test_fetchModels_exo_requestsDownloadedOnly \
  CODE_SIGNING_ALLOWED=NO test
```

Expected: **FAIL** — URL contains `/v1/models` but not `status=downloaded` (exo still in the generic arm).

- [ ] **Step 3: Give exo its own fetch arm**

In `Modelo/Services/LMStudioClient.swift:fetchModels`, remove `.exo` from the `.llamaCpp, .oMLX, .exo` arm (back to `.llamaCpp, .oMLX`) and add a dedicated arm:

```swift
        case .llamaCpp, .oMLX:
            // Generic local OpenAI-compatible servers (llama.cpp/llama-swap, oMLX): no /api/v0.
            return try await fetch(path: "/v1/models", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
        case .exo:
            // exo's /v1/models is its full downloadable catalog; the downloaded-only
            // filter returns just the models present on the machine.
            return try await fetch(path: "/v1/models?status=downloaded", endpoint: endpoint)
                .filter { !$0.isEmbeddingModel }
```

- [ ] **Step 4: Run test to verify it passes**

Run the same `-only-testing:` command from Step 2. Expected: **PASS**.

- [ ] **Step 5: Run the full suite**

Expected: all green.

- [ ] **Step 6: Manual verification against live exo**

exo is running on `localhost:52415` with 10 bridged MLX models. Build & run the app, add a server: runtime **exo**, host `localhost`, port `52415`. Confirm the model picker shows **only those ~10 models** (not ~130), and that chatting with one already launched in exo streams a reply.

- [ ] **Step 7: Commit**

```bash
git add Modelo/Services/LMStudioClient.swift ModeloTests/LMStudioClientTests.swift
git commit -m "feat(exo): list only downloaded models via status=downloaded"
```

**Tier 1 is complete after Task 2.** exo endpoints show only local models; chat works for launched models.

---

# TIER 2 — Native load-state + place/unplace

## Task 3: `ExoClient` — decode `/state` instances, place & delete instances

exo's cluster API is camelCase with wrapper keys (e.g. `MlxRingInstance`) and lives at `/state`, `/place_instance`, `/instance/{id}` — different enough from the LM Studio shapes to warrant a dedicated client.

**Files:**
- Create: `Modelo/Services/ExoClient.swift`
- Create: `ModeloTests/ExoClientTests.swift`
- (After creating the files) run `xcodegen generate` so they join the targets.

- [ ] **Step 1: Write the failing tests**

Create `ModeloTests/ExoClientTests.swift`:

```swift
import XCTest
@testable import Modelo

final class ExoClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func client() -> ExoClient { ExoClient(session: StubURLProtocol.makeSession()) }
    private func exo() -> Endpoint { Endpoint(baseURL: "http://localhost:52415", kind: .exo, apiKey: nil) }

    func test_loadedInstances_decodesWrappedCamelCase() async throws {
        let body = """
        {"instances":{"959b7da3":{"MlxRingInstance":{"instanceId":"959b7da3",
        "shardAssignments":{"modelId":"lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit"}}}}}
        """
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/state"))
            return (.stub(200), Data(body.utf8))
        }
        let loaded = try await client().loadedInstances(endpoint: exo())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.instanceID, "959b7da3")
        XCTAssertEqual(loaded.first?.modelID, "lmstudio-community/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit")
    }

    func test_loadedInstances_emptyWhenNoInstances() async throws {
        StubURLProtocol.handler = { _ in (.stub(200), Data(#"{"instances":{}}"#.utf8)) }
        let loaded = try await client().loadedInstances(endpoint: exo())
        XCTAssertTrue(loaded.isEmpty)
    }

    func test_placeInstance_postsModelIdWithDefaults() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/place_instance"))
            return (.stub(200), Data(#"{"message":"Command received."}"#.utf8))
        }
        try await client().placeInstance(modelID: "org/model-4bit", endpoint: exo())
        let sent = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
        XCTAssertEqual(json["model_id"] as? String, "org/model-4bit")
        XCTAssertEqual(json["sharding"] as? String, "Pipeline")
        XCTAssertEqual(json["instance_meta"] as? String, "MlxRing")
        XCTAssertEqual(json["min_nodes"] as? Int, 1)
    }

    func test_deleteInstance_sendsDeleteToInstancePath() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/instance/959b7da3"))
            return (.stub(200), Data(#"{"message":"deleted"}"#.utf8))
        }
        try await client().deleteInstance(instanceID: "959b7da3", endpoint: exo())
    }
}
```

- [ ] **Step 2: Create `ExoClient` (make it compile, tests fail on behavior)**

Create `Modelo/Services/ExoClient.swift`:

```swift
import Foundation

/// A loaded exo instance: which model it serves and the instance id to unload it.
struct ExoLoadedInstance: Equatable {
    let instanceID: String
    let modelID: String
}

/// Minimal client for exo's cluster API. Kept separate from `LMStudioClient`
/// because exo's `/state` and instance payloads are camelCase with variant
/// wrapper keys (e.g. `MlxRingInstance`) — a different wire contract.
final class ExoClient {
    private let session: URLSession
    init(session: URLSession = LMStudioClient.defaultSession()) { self.session = session }

    /// Models that currently have a placed (loaded) instance in exo.
    func loadedInstances(endpoint: Endpoint) async throws -> [ExoLoadedInstance] {
        let data = try await send("GET", "/state", endpoint: endpoint)
        let state = try JSONDecoder().decode(ExoState.self, from: data)
        return state.instances.values.compactMap { inst in
            guard let modelID = inst.modelID, let instanceID = inst.instanceID else { return nil }
            return ExoLoadedInstance(instanceID: instanceID, modelID: modelID)
        }
    }

    /// Place (load) a model as a single-node pipeline instance.
    func placeInstance(modelID: String, endpoint: Endpoint) async throws {
        let body = try JSONEncoder().encode(PlaceInstanceRequest(modelID: modelID))
        _ = try await send("POST", "/place_instance", endpoint: endpoint, body: body)
    }

    /// Delete (unload) a placed instance by its id.
    func deleteInstance(instanceID: String, endpoint: Endpoint) async throws {
        _ = try await send("DELETE", "/instance/\(instanceID)", endpoint: endpoint)
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, endpoint: Endpoint,
                      body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { throw ExoError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExoError.requestFailed
        }
        return data
    }

    enum ExoError: Error { case invalidURL, requestFailed }
}

// MARK: - Wire types

/// exo `/place_instance` request. exo expects snake_case; single-node pipeline defaults.
private struct PlaceInstanceRequest: Encodable {
    let modelID: String
    var sharding = "Pipeline"
    var instanceMeta = "MlxRing"
    var minNodes = 1
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case sharding
        case instanceMeta = "instance_meta"
        case minNodes = "min_nodes"
    }
}

/// exo `/state` — we only decode the instances map.
private struct ExoState: Decodable {
    let instances: [String: ExoInstance]
}

/// An instance is wrapped in a variant key (e.g. "MlxRingInstance"); we probe the
/// first wrapper value for `instanceId` + `shardAssignments.modelId`.
private struct ExoInstance: Decodable {
    let instanceID: String?
    let modelID: String?

    private struct Body: Decodable {
        let instanceId: String?
        let shardAssignments: ShardAssignments?
        struct ShardAssignments: Decodable { let modelId: String? }
    }
    private struct DynamicKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            if let body = try? container.decode(Body.self, forKey: key) {
                instanceID = body.instanceId
                modelID = body.shardAssignments?.modelId
                return
            }
        }
        instanceID = nil; modelID = nil
    }
}
```

- [ ] **Step 3: Regenerate the project so new files are in the targets**

Run: `xcodegen generate`

- [ ] **Step 4: Run the ExoClient tests**

Run:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ModeloTests/ExoClientTests CODE_SIGNING_ALLOWED=NO test
```

Expected: **TEST SUCCEEDED** (all four).

- [ ] **Step 5: Commit**

```bash
git add Modelo/Services/ExoClient.swift ModeloTests/ExoClientTests.swift project.yml Modelo.xcodeproj
git commit -m "feat(exo): add ExoClient for state, place, and delete instance"
```

---

## Task 4: Show real exo load-state in the model picker

`ServerMonitor` only polls `.lmStudio` servers today (`start(...)` filters `where server.kind == .lmStudio`), and `poll` hardcodes `kind: .lmStudio`. `ModelSnapshot` holds `[LMStudioModel]` (the loaded ones). For exo we must (a) also start a loop for `.exo` servers, and (b) build the loaded set from `ExoClient.loadedInstances` intersected with the downloaded model list.

**Files:**
- Modify: `Modelo/Services/ServerMonitor.swift` (`init`, `start`, `poll`)
- Test: `ModeloTests/ServerMonitorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `ModeloTests/ServerMonitorTests.swift` (mirror the existing setup — insert the `Server` into an in-memory `ModelContext` so `persistentModelID` is stable, as other tests here do). The stub answers `/state` with one placed instance and the model list with two models; the snapshot should contain exactly the placed model:

```swift
@MainActor
func test_poll_exo_snapshotContainsOnlyPlacedModels() async throws {
    let models = #"{"data":[{"id":"org/a","object":"model"},{"id":"org/b","object":"model"}]}"#
    let state = #"{"instances":{"i1":{"MlxRingInstance":{"instanceId":"i1","shardAssignments":{"modelId":"org/b"}}}}}"#
    StubURLProtocol.handler = { req in
        if req.url!.absoluteString.contains("/state") { return (.stub(200), Data(state.utf8)) }
        return (.stub(200), Data(models.utf8))
    }
    let schema = Schema([Server.self, ModelContextOverride.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
    let server = Server(label: "exo", host: "localhost", port: 52415, kind: .exo)
    context.insert(server)

    let monitor = ServerMonitor(client: LMStudioClient(session: StubURLProtocol.makeSession()),
                                exoClient: ExoClient(session: StubURLProtocol.makeSession()))
    await monitor.poll(server)

    let snapshot = monitor.snapshot(for: server)
    XCTAssertEqual(snapshot?.models.map(\.id), ["org/b"])
}
```

> Add `import SwiftData` to the test file if not already present.

- [ ] **Step 2: Run it to verify failure**

Run:

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ModeloTests/ServerMonitorTests/test_poll_exo_snapshotContainsOnlyPlacedModels \
  CODE_SIGNING_ALLOWED=NO test
```

Expected: **FAIL** — `ServerMonitor` has no `exoClient:` parameter (build error), or once added, the snapshot is empty/wrong because `poll` builds an `.lmStudio` endpoint.

- [ ] **Step 3: Inject `ExoClient` and branch `poll`; start exo loops**

In `Modelo/Services/ServerMonitor.swift`:

Add the stored client + init parameter:

```swift
    private let client: any ChatProvider
    private let exoClient: ExoClient

    init(client: any ChatProvider = LMStudioClient.shared,
         exoClient: ExoClient = ExoClient()) {
        self.client = client
        self.exoClient = exoClient
    }
```

In `start(...)`, also loop exo servers — change the filter:

```swift
        for server in servers where server.kind == .lmStudio || server.kind == .exo {
```

At the top of `poll(_:)`, branch exo before the LM Studio logic:

```swift
    func poll(_ server: Server) async {
        if server.kind == .exo {
            let endpoint = Endpoint(baseURL: server.baseURL, kind: .exo, apiKey: nil)
            guard let all = try? await client.fetchModels(endpoint: endpoint),
                  let loaded = try? await exoClient.loadedInstances(endpoint: endpoint) else { return }
            let loadedIDs = Set(loaded.map(\.modelID))
            snapshots[server.persistentModelID] = ModelSnapshot(models: all.filter { loadedIDs.contains($0.id) })
            return
        }
        let endpoint = Endpoint(baseURL: server.baseURL, kind: .lmStudio, apiKey: nil)
        // ... existing LM Studio logic unchanged ...
```

- [ ] **Step 4: Run the test — expect PASS**

Run the same `-only-testing:` command from Step 2. Expected: **PASS**.

- [ ] **Step 5: Run the full suite**

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Modelo/Services/ServerMonitor.swift ModeloTests/ServerMonitorTests.swift
git commit -m "feat(exo): poll exo servers and derive load-state from placed instances"
```

---

## Task 5: Load / Unload exo models from Modelo

Wire the model picker's load/unload affordance for exo to `ExoClient.placeInstance` / `deleteInstance`, with a RAM-cost confirmation on load. No auto-place-on-select.

**Files:**
- Modify: `Modelo/ContentView.swift` — three action sites: `:240` (load), `:461` (unload), `:508` (load).

- [ ] **Step 1: Read the three call sites and their in-scope variables**

The sites are exactly:
- `ContentView.swift:240` → `client.loadModel(modelID: model.model.id, endpoint: endpoint)`
- `ContentView.swift:461` → `client.unloadModel(modelID: item.model.id, endpoint: endpoint)`
- `ContentView.swift:508` → `client.loadModel(modelID: item.model.id, endpoint: endpoint)`

Read ~15 lines around each to confirm the in-scope `server`/`endpoint`/model-id expression (`model.model.id` at :240, `item.model.id` at :461/:508). You'll need an `ExoClient` instance available here (add a `let exoClient = ExoClient()` property to the view, or inject via `@Environment` alongside the existing `client`).

- [ ] **Step 2: Branch the action for exo**

Where the load action runs, branch on `server.kind == .exo`:

```swift
if server.kind == .exo {
    // exo loads a model by placing an instance; it consumes GBs of RAM.
    let confirmed = await confirmPlacement(modelID: model.id)   // simple SwiftUI .confirmationDialog
    guard confirmed else { return }
    try await exoClient.placeInstance(modelID: model.id, endpoint: endpoint)
} else {
    _ = try await client.loadModel(modelID: model.id, endpoint: endpoint)
}
```

For unload:

```swift
if server.kind == .exo {
    guard let instance = (try? await exoClient.loadedInstances(endpoint: endpoint))?
            .first(where: { $0.modelID == model.id }) else { return }
    try await exoClient.deleteInstance(instanceID: instance.instanceID, endpoint: endpoint)
} else {
    _ = try await client.unloadModel(modelID: model.id, endpoint: endpoint)
}
```

Add a `.confirmationDialog` presenting model id + "This loads the model into exo and uses several GB of RAM. Continue?" with Load / Cancel.

- [ ] **Step 3: Build & run — manual verification**

Against live exo: an unloaded (idle) exo model shows a Load control; loading it shows the confirmation, then the model transitions to loaded (via Task 4's polling) and chat works without visiting exo's dashboard. Unload returns it to idle.

- [ ] **Step 4: Run the full suite**

Expected: all green (no regressions).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(exo): load/unload models via place/delete instance with RAM confirmation"
```

**Tier 2 complete:** exo models show accurate loaded/idle state and can be loaded/unloaded from Modelo.

---

## Self-review notes

- **Spec coverage:** Tier 1 (dedicated kind + downloaded-only fetch) → Tasks 1–2. Tier 2 (load-state + place/unplace, dedicated `ExoClient`, explicit Load w/ confirmation) → Tasks 3–5. Tier 3 (cluster status) intentionally omitted (out of scope in spec).
- **Compiler-forced touchpoints:** all seven `ServerKind` switch sites are edited in Task 1; `localIcon` has a `default` (not forced) so exo's icon is added explicitly; `hint` is exhaustive (forced).
- **Type consistency:** `ExoLoadedInstance(instanceID:modelID:)`, `ExoClient.loadedInstances/placeInstance/deleteInstance`, and `PlaceInstanceRequest` snake_case keys are used identically across Tasks 3–5. Task 4 uses the real `ModelSnapshot { models: [LMStudioModel] }` shape and `ServerMonitor(client:exoClient:)` init.
- **Verified against source:** `ServerMonitor` internals (`ModelSnapshot`, `start` filter, `poll`), the three load/unload sites (`ContentView.swift:240/461/508`), and all seven Tier-1 `ServerKind` switch sites were read directly. Task 5's UI still requires reading ~15 lines of context around each site during implementation (flagged in its Step 1), since the surrounding view state isn't reproduced here.
