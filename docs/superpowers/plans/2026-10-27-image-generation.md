# Image Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate images inline in chat (`/image` and a `generate_image` tool) on OpenRouter, OpenAI-style Cloud APIs, Unsloth Studio and ComfyUI, and let HTML artifacts in the same conversation embed them.

**Architecture:** Three stateless `ImageGenerator` adapters behind one protocol; a `@MainActor ImageService` that picks the adapter from the conversation's image server, persists `GeneratedImage` rows and assigns per-conversation `img-N` handles. Every renderer (message markdown, tool card, artifact preview/export) resolves `modelo-image:img-N` against the conversation's images through one `ImageReference` value passed down the SwiftUI environment.

**Tech Stack:** Swift / SwiftUI (macOS), SwiftData, URLSession, MarkdownUI 2.4 (`ImageProvider`), XCTest with `StubURLProtocol`.

**Spec:** `docs/superpowers/specs/2026-10-27-image-generation-design.md`

## Global Constraints

- Ship as **two PRs** (spec § Size and decomposition). Part 1 = Tasks 1–9, Part 2 = Tasks 10–12. Stop after Task 9 for human review (AGENTS.md: pause on UI/schema changes).
- Reference scheme is exactly `modelo-image:img-N`; handles are `img-1`, `img-2`, … per conversation, `max(existing) + 1`, never reused.
- Default size `1024x1024`. Tool parameters: `prompt` (required), `size` (optional). No steps/CFG/sampler/negative-prompt controls.
- ComfyUI: poll every 1 s, time out after 5 min with `ComfyUI timed out after 5 min`.
- `.comfyUI` default port 8188, no key, image-only. `.unsloth` default port 8888, bearer key `sk-unsloth-…`, chat + image. Both `isLocal == true`.
- Error copy, verbatim: `Rate limited by the provider — try again in Ns.` / `Rate limited by the provider — try again shortly.` / `Server returned HTTP N` / `<model> returned no image` / `Pick an image model first.`
- No new dependencies.
- New files are picked up by XcodeGen: run `xcodegen generate` after adding any file.
- **TEST** below means:
  `xcodebuild -project Modelo.xcodeproj -scheme Modelo -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test -only-testing:ModeloTests/<Suite>`
  A pass is `** TEST SUCCEEDED **`. **BUILD** is the AGENTS.md build command; a pass is `** BUILD SUCCEEDED **`.

## Review Focus

1. **`img-1` vs `img-10` prefix collision** — an artifact using both must get two different images. Resolver matches the whole handle (`modelo-image:(img-\d+)`), never a plain prefix replace. Test in Task 8.
2. **Prompt text in markdown alt text** — a prompt containing `]`, `[`, or newlines must not break `![…](modelo-image:…)`. Alt text is sanitized (brackets and newlines → space, capped at 100 chars). Test in Task 7.
3. **Malformed `size` from a model** (`"1024*1024"`, `"large"`, `"0x0"`) — fall back to `1024x1024`, don't fail the call. Test in Task 2.
4. **ComfyUI `/object_info` in the newer `["COMBO", {"options": […]}]` shape** — checkpoints must still list. Test in Task 4.
5. **Stop pressed mid-generation** — no `GeneratedImage` row and no assistant message is saved; the handle counter doesn't advance. Test in Task 6.

---

## Part 1 — adapters, storage, `/image`, picker

### Task 1: Shared HTTP error classification

**Files:**
- Create: `Modelo/Services/HTTPError.swift`
- Modify: `Modelo/Services/LMStudioClient.swift:451-480` (stream error path), `:561-564` (delete private `HTTPErrorBody`)
- Test: `ModeloTests/HTTPErrorTests.swift`

**Interfaces:**
- Produces: `enum HTTPError { static func error(status: Int, headers: [AnyHashable: Any], body: Data) -> ClientError }`. Returns `.authRequired` for 401/403, else provider message from `{"error":{"message"}}` or `[{"error":{"message"}}]`, else the 429 copy, else `.serverError("Server returned HTTP N")`. Callers check `(200..<300).contains(status)` themselves.

- [ ] **Step 1:** Write `HTTPErrorTests`: `test_401_isAuthRequired`, `test_providerMessage_object`, `test_providerMessage_array` (`[{"error":{"message":"Quota exceeded"}}]` → `.serverError("Quota exceeded")`), `test_bare429_withRetryAfter` (header `Retry-After: 30` → `.serverError("Rate limited by the provider — try again in 30s.")`), `test_bare429_noHeader` (`…try again shortly.`), `test_500_bare` (`.serverError("Server returned HTTP 500")`).
- [ ] **Step 2:** TEST `HTTPErrorTests` → fails (type missing).
- [ ] **Step 3:** Implement `HTTPError.error(status:headers:body:)` by moving the logic from `streamOnce`; `streamOnce` reads up to 4096 bytes then `throw HTTPError.error(status: http.statusCode, headers: http.allHeaderFields, body: errorData)`. Keep the existing 401/403 comment with the moved code.
- [ ] **Step 4:** TEST `HTTPErrorTests` and `LMStudioClientTests` → both pass unchanged.
- [ ] **Step 5:** Commit `refactor(net): share HTTP error classification so image clients reuse it`.

### Task 2: `ImageGenerator` protocol + `OpenAIImagesClient`

**Files:**
- Create: `Modelo/Services/ImageGenerator.swift`, `Modelo/Services/OpenAIImagesClient.swift`
- Test: `ModeloTests/OpenAIImagesClientTests.swift`

**Interfaces:**
- Produces:
  - `struct ImageModel: Sendable, Hashable, Identifiable { let id: String; let displayName: String }`
  - `struct ImageRequest: Sendable, Equatable { let prompt: String; let width: Int; let height: Int; let modelID: String; var seed: Int? = nil; var sizeString: String { "\(width)x\(height)" } }` plus `init(prompt:size:modelID:seed:)` taking `size: String?` and falling back to 1024×1024 when it doesn't parse as `<1–4096>x<1–4096>`.
  - `protocol ImageGenerator: Sendable { func listModels(endpoint: Endpoint) async throws -> [ImageModel]; func generate(_ request: ImageRequest, endpoint: Endpoint) async throws -> [Data] }`
  - `final class OpenAIImagesClient: ImageGenerator { init(session: URLSession = LMStudioClient.defaultSession()) }`
- Path rule (matches `streamOnce`'s `chatPath`): `.unsloth` → `/v1/images/generations` and `/v1/models`; `.cloudAPI` → `/images/generations` and `/models`. Bearer from `endpoint.apiKey` when present.
- Body: `{"model", "prompt", "n": 1, "size": "WxH", "response_format": "b64_json"}`. Decode `data[].b64_json`. Empty → `ClientError.serverError("\(modelID) returned no image")`. `listModels` returns every id from `/models` (no image filter exists on generic APIs).

- [ ] **Step 1:** Write tests: `test_generate_postsToImagesPath_withBearerAndBody` (cloudAPI base `https://api.example.com/v1` → URL `https://api.example.com/v1/images/generations`, `Authorization: Bearer k`, body fields above); `test_generate_unslothUsesV1Path`; `test_generate_decodesB64` (returns the decoded bytes); `test_generate_noImages_errors` (`{"data":[]}` → `.serverError("m returned no image")`); `test_generate_400_contentPolicy` (`{"error":{"message":"Your request was rejected"}}` → that message); `test_generate_429_rateLimited`; `test_request_badSize_defaults` — `ImageRequest(prompt:"p", size:"large", modelID:"m")` and `"1024*1024"` and `"0x0"` all give `1024x1024`; `"512x768"` gives 512×768.
- [ ] **Step 2:** `xcodegen generate`, TEST `OpenAIImagesClientTests` → fails.
- [ ] **Step 3:** Implement. Non-2xx → `throw HTTPError.error(...)`.
- [ ] **Step 4:** TEST → pass.
- [ ] **Step 5:** Commit `feat(images): ImageGenerator protocol and OpenAI-style images client`.

### Task 3: `OpenRouterImagesClient`

**Files:**
- Create: `Modelo/Services/OpenRouterImagesClient.swift`
- Modify: `Modelo/Services/OpenRouterCatalog.swift` (add `imageModels(from:)`)
- Test: `ModeloTests/OpenRouterImagesClientTests.swift`

**Interfaces:**
- Consumes: `ImageGenerator`, `ImageModel`, `ImageRequest`, `HTTPError` (Tasks 1–2).
- Produces: `final class OpenRouterImagesClient: ImageGenerator { init(session:) }`; `OpenRouterCatalog.imageModels(from data: Data) throws -> [ImageModel]` — entries whose `architecture.output_modalities` contains `"image"`; `displayName` = the entry's `name` (add `name: String?` to `Entry`), falling back to `id`.
- Generate: `POST {base}/chat/completions`, body `{"model", "messages":[{"role":"user","content":prompt}], "modalities":["image","text"], "stream": false}`. Decode `choices[0].message.images[].image_url.url`, each a `data:<mime>;base64,<b64>` URL → bytes. `size` is not sent (OpenRouter has no uniform size param).

- [ ] **Step 1:** Write tests: `test_body_hasModalitiesAndStreamFalse`; `test_decodesDataURLImages` (two images → two `Data`); `test_noImages_errors` (message with only `content` → `.serverError("google/gemini-x returned no image")`); `test_catalog_filtersToImageOutput` (one text-only, one `["image","text"]` entry → only the latter, display name from `name`).
- [ ] **Step 2:** `xcodegen generate`, TEST `OpenRouterImagesClientTests` → fails.
- [ ] **Step 3:** Implement. `listModels` = `GET {base}/models` → `OpenRouterCatalog.imageModels(from:)`.
- [ ] **Step 4:** TEST `OpenRouterImagesClientTests` and `OpenRouterCatalogTests` → pass.
- [ ] **Step 5:** Commit `feat(images): OpenRouter image generation via chat modalities`.

### Task 4: `ComfyUIClient`

**Files:**
- Create: `Modelo/Services/ComfyUIClient.swift`
- Test: `ModeloTests/ComfyUIClientTests.swift`

**Interfaces:**
- Produces: `final class ComfyUIClient: ImageGenerator { init(session: URLSession = LMStudioClient.defaultSession(), pollInterval: Duration = .seconds(1), timeout: Duration = .seconds(300)); static func graph(for request: ImageRequest, seed: Int) -> [String: Any] }`.
- `listModels`: `GET /object_info/CheckpointLoaderSimple` → `CheckpointLoaderSimple.input.required.ckpt_name`, which is either `[[names…], {…}]` (legacy) or `["COMBO", {"options": [names…]}]` (newer). `ImageModel(id: name, displayName: name minus extension)`.
- Generate: `POST /prompt` `{"prompt": graph, "client_id": <UUID>}` → `prompt_id`; poll `GET /history/{id}` until it has the id; read `outputs["9"].images[0]` → `GET /view?filename=&subfolder=&type=output`. Seed = `request.seed ?? Int.random(in: 0...Int(UInt32.max))`.
- Errors: non-empty `node_errors` in the `/prompt` response (200 or 400) → `.serverError("<class_type>: <first errors[].message> — <details>")`; history `status.status_str == "error"` → `.serverError(<exception_message from the execution_error entry in status.messages>)`; timeout → `.serverError("ComfyUI timed out after 5 min")`. On `CancellationError` fire-and-forget `POST /interrupt` (unstructured `Task`, since the current one is cancelled) and rethrow.
- Graph — exact values (node IDs are the injection points):

```swift
"4": CheckpointLoaderSimple   ckpt_name = request.modelID
"6": CLIPTextEncode           text = request.prompt, clip = ["4", 1]
"7": CLIPTextEncode           text = "",             clip = ["4", 1]
"5": EmptyLatentImage         width, height, batch_size = 1
"3": KSampler                 seed, steps = 20, cfg = 7, sampler_name = "euler",
                              scheduler = "normal", denoise = 1,
                              model = ["4", 0], positive = ["6", 0],
                              negative = ["7", 0], latent_image = ["5", 0]
"8": VAEDecode                samples = ["3", 0], vae = ["4", 2]
"9": SaveImage                filename_prefix = "modelo", images = ["8", 0]
```

- [ ] **Step 1:** Write tests (stub handler switches on `request.url.path`): `test_listModels_legacyShape`; `test_listModels_comboShape` (Review Focus 4); `test_graph_injectsPromptSeedCheckpointSize` (assert `graph["6"]` text, `graph["3"]` seed, `graph["4"]` ckpt, `graph["5"]` 512/768); `test_generate_promptHistoryView_sequence` (first `/history` call returns `{}`, second returns outputs; result is the `/view` bytes; `/view` query has `filename`, `subfolder`, `type=output`); `test_nodeErrors_surface` (→ message contains `CheckpointLoaderSimple` and the reason); `test_historyErrorStatus_surfacesException`; `test_timeout` (`timeout: .milliseconds(50)`, `/history` always `{}` → `.serverError("ComfyUI timed out after 5 min")`). Use `pollInterval: .milliseconds(1)` in tests.
- [ ] **Step 2:** `xcodegen generate`, TEST `ComfyUIClientTests` → fails.
- [ ] **Step 3:** Implement. Store the graph as a Swift dictionary literal in `graph(for:seed:)`; encode with `JSONSerialization`.
- [ ] **Step 4:** TEST → pass.
- [ ] **Step 5:** Commit `feat(images): ComfyUI txt2img client with a built-in graph`.

### Task 5: `.comfyUI` and `.unsloth` server kinds

**Files:**
- Modify: `Modelo/Services/Endpoint.swift` (`ServerKind`), `Modelo/Models/Server.swift:58-66`, `Modelo/Services/LMStudioClient.swift` (switches at ~51, ~129, ~181, ~434, `classifyKind`), `Modelo/Services/ReachabilityMonitor.swift:44`, `Modelo/Settings/SettingsView.swift` (~284, ~1360), `Modelo/Views/ServerStatsView.swift:215`. The compiler lists the rest.
- Test: `ModeloTests/EndpointTests.swift`, `ModeloTests/LMStudioClientTests.swift`

**Interfaces:**
- Produces: `case comfyUI` (raw `"comfyUI"`), `case unsloth` (raw `"unsloth"`); `displayName` `"ComfyUI"` / `"Unsloth Studio"`; `var canChat: Bool` (false only for `.comfyUI`); `var canGenerateImages: Bool` (true for `.openRouter`, `.cloudAPI`, `.unsloth`, `.comfyUI`).
- Behavior: `.unsloth` is wire-identical to `.llamaCpp` for chat (`/v1/...`) plus bearer. `.comfyUI`: `fetchModels` returns `[]`; `probeReachable`/`probeDetailed` use `/system_stats`; never in the chat picker (follows from `fetchModels` returning `[]`). `classifyKind`: port 8188 → `.comfyUI`, 8888 → `.unsloth`. Settings hint copy: ComfyUI `"Image generation only — start ComfyUI and point this at its port (default 8188)."`; Unsloth `"Start Unsloth Studio (default port 8888) and paste its API key (sk-unsloth-…)."`

- [ ] **Step 1:** Write tests: `test_newKinds_defaults` (ports, `isLocal`, `canChat`, `canGenerateImages` for all 11 kinds); `test_newKinds_rawValuesRoundTrip`; in `LMStudioClientTests` `test_probe_comfyUI_hitsSystemStats` and `test_fetchModels_comfyUI_isEmpty` (no request made).
- [ ] **Step 2:** TEST `EndpointTests` → fails.
- [ ] **Step 3:** Add the cases, then BUILD and fix every exhaustive-switch error.
- [ ] **Step 4:** TEST `EndpointTests`, `LMStudioClientTests`, `ReachabilityMonitorTests` → pass.
- [ ] **Step 5:** Commit `feat(servers): add ComfyUI and Unsloth Studio server kinds`.

### Task 6: `GeneratedImage` storage + `ImageService`

**Files:**
- Create: `Modelo/Models/GeneratedImage.swift`, `Modelo/Services/ImageService.swift`
- Modify: `Modelo/Models/Conversation.swift`, `Modelo/ModeloApp.swift:48` (schema)
- Test: `ModeloTests/ImageServiceTests.swift`

**Interfaces:**
- Consumes: `ImageGenerator`, `ImageRequest`, `ImageModel`, `ServerKind.canGenerateImages`.
- Produces:
  - `@Model final class GeneratedImage { var handle: String; var prompt: String; var modelID: String; var createdAt: Date; @Attribute(.externalStorage) var data: Data; var conversation: Conversation?; var mimeType: String }`. `mimeType` is computed from magic bytes: PNG `89 50 4E 47`, JPEG `FF D8`, WebP `RIFF…WEBP`, else `image/png`.
  - `Conversation`: `var imageServerID: UUID?`, `var imageModelID: String?`, `@Relationship(deleteRule: .cascade, inverse: \GeneratedImage.conversation) var images: [GeneratedImage] = []`.
  - `@MainActor final class ImageService { init(context: ModelContext, keychain: KeychainStore = KeychainStore(), generatorFor: @escaping @Sendable (ServerKind) -> (any ImageGenerator)? = ImageService.defaultGenerator); static func defaultGenerator(_ kind: ServerKind) -> (any ImageGenerator)?; func listModels(server: Server) async throws -> [ImageModel]; func generate(prompt: String, size: String?, in conversation: Conversation) async throws -> GeneratedImage; static func nextHandle(in conversation: Conversation) -> String }`.
  - `defaultGenerator`: `.openRouter` → OpenRouter client; `.cloudAPI`, `.unsloth` → OpenAI client; `.comfyUI` → ComfyUI client; else nil.
  - `generate` throws `ClientError.serverError("Pick an image model first.")` when `imageServerID`/`imageModelID` is nil or the server row is gone. It checks `Task.checkCancellation()` after the network call and before inserting, so a stopped run saves nothing. It saves with `context.saveOrLog()`.

- [ ] **Step 1:** Write tests (in-memory container with `GeneratedImage` in the schema; stub generator returning fixed PNG bytes): `test_handles_numberPerConversation` (two conversations each get `img-1`); `test_handles_neverReused` (create 3, delete `img-2` → next is `img-4`); `test_cascadeDelete` (deleting the conversation deletes its images); `test_noImageModel_throwsPickFirst`; `test_cancelledMidGeneration_savesNothing` (the stub generator awaits a continuation; cancel the task; assert `images.isEmpty` and that `nextHandle` is still `img-1`; Review Focus 5); `test_mimeSniff` (PNG / JPEG / WebP headers).
- [ ] **Step 2:** `xcodegen generate`, TEST `ImageServiceTests` → fails.
- [ ] **Step 3:** Implement. `nextHandle` parses the digits from `images[].handle` and returns `img-<max+1>`, or `img-1` for none. Add `GeneratedImage.self` to the app schema. If other suites' `makeContext` schemas fail to build containers, add `GeneratedImage.self` there too.
- [ ] **Step 4:** TEST `ImageServiceTests`, `ConversationTests`, `StoreRecoveryTests` → pass.
- [ ] **Step 5:** Commit `feat(images): persist generated images per conversation with img-N handles`.

### Task 7: `/image` command

**Files:**
- Modify: `Modelo/Services/SlashParser.swift`, `Modelo/Services/ChatSession.swift`, `Modelo/Views/ChatView.swift` (`handleSlash` ~1595, session build ~1525, status row near the streaming indicator)
- Test: `ModeloTests/SlashParserTests.swift`, `ModeloTests/ChatSessionTests.swift`

**Interfaces:**
- Consumes: `ImageService.generate(prompt:size:in:)`.
- Produces: `SlashCommand.image(String)` (aliases `image`, `img`; empty arg → nil, sent as text); catalog `Spec(token: "image", arg: "<prompt>", summary: "Generate an image")`; `helpText` gains `/image <prompt>`. `ChatSession` gains `init(..., imageService: ImageService? = nil)`, `private(set) var isGeneratingImage = false`, `func generateImage(prompt: String, in conversation: Conversation) async`, and `static func markdownImage(prompt: String, handle: String) -> String`, which returns `![<alt>](modelo-image:<handle>)`. Alt text is the prompt with `[`, `]`, `\n` replaced by spaces, trimmed, and capped at 100 chars.
- `generateImage`: append user message `"/image <prompt>"` → set `isStreaming` and `isGeneratingImage` true → `imageService.generate(prompt:size:nil,in:)` → append assistant message `markdownImage(...)`. On error, set `errorText` to the `ClientError` description and append no assistant message. On cancel, do nothing more. Set the title the same way `send` does.
- ChatView: `.image(prompt)` → if `conversation.imageModelID == nil` → `flash("Pick an image model first.")`; else run via `sessionStore.setTask(Task { await session.generateImage(...) })` so the existing Stop button cancels it. While `isGeneratingImage`, show a `ProgressView` plus `"Generating image…"` in the streaming-indicator spot. Pass `ImageService(context: context, keychain: keychain)` into the `ChatSession` init.

- [ ] **Step 1:** Write tests: `SlashParserTests.test_image` (`/image a fox` → `.image("a fox")`, `/img x` → `.image("x")`, `/image` → nil); `ChatSessionTests.test_markdownImage_sanitizesAlt` (`"a [red]\nfox"` → `![a  red  fox](modelo-image:img-1)`; a 300-char prompt is capped at 100; Review Focus 2); `ChatSessionTests.test_generateImage_appendsUserAndAssistant` (stub generator; path ends `[user "/image fox", assistant "![fox](modelo-image:img-1)"]`); `test_generateImage_error_setsErrorText_noAssistant`.
- [ ] **Step 2:** TEST `SlashParserTests`, `ChatSessionTests` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** TEST both suites → pass; BUILD.
- [ ] **Step 5:** Commit `feat(images): /image command generates into the thread`.

### Task 8: `ImageReference` + images in message bubbles

**Files:**
- Create: `Modelo/Services/ImageReference.swift`, `Modelo/Views/ModeloImageProvider.swift`
- Modify: `Modelo/Views/MarkdownText.swift` (apply provider), `Modelo/Views/ChatView.swift` (set environment)
- Test: `ModeloTests/ImageReferenceTests.swift`

**Interfaces:**
- Consumes: `GeneratedImage`.
- Produces:
  - `struct ImageReference { init(images: [GeneratedImage]); func image(for handle: String) -> GeneratedImage?; func dataURL(for handle: String) -> String?; func resolveHTML(_ html: String) -> String; static func handles(in text: String) -> [String]; static let scheme = "modelo-image" }`. Matching uses the regex `modelo-image:(img-\d+)` with a non-digit boundary after it. Data URLs are built lazily per lookup, not up front.
  - `resolveHTML` replaces each match with the image's data URL, or with `ImageReference.missingPlaceholder(handle)`. That is a `data:image/svg+xml;utf8,` 320×180 grey SVG reading `Missing image <handle>`.
  - `extension EnvironmentValues { @Entry var imageReference = ImageReference(images: []) }`. ChatView sets `.environment(\.imageReference, ImageReference(images: conversation.images))` on its body.
  - `struct ModeloImageProvider: ImageProvider`. For a `modelo-image` URL it shows `Image(nsImage:)`, resizable and scaled to fit, max width 512, corner radius `Theme.Radius.field`. For a missing handle it shows a `Theme.fill` box with `"Missing image <handle>"`. Any other URL goes to `DefaultImageProvider()`. `MarkdownText` reads the environment value and applies `.markdownImageProvider(ModeloImageProvider(reference:))`.

- [ ] **Step 1:** Write tests: `test_resolveHTML_replacesHandle`; `test_resolveHTML_img1_vs_img10` (both present → each gets its own data URL; Review Focus 1); `test_resolveHTML_cssUrl` (`background:url(modelo-image:img-1)` resolved); `test_missingHandle_placeholder`; `test_handlesInText` (ordered and de-duplicated).
- [ ] **Step 2:** `xcodegen generate`, TEST `ImageReferenceTests` → fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** TEST → pass; BUILD.
- [ ] **Step 5:** Commit `feat(images): render modelo-image references in message bubbles`.

### Task 9: Image model picker + discovery

**Files:**
- Create: `Modelo/Views/ImageModelPicker.swift`
- Modify: `Modelo/ContentView.swift` (`refreshModels` ~608, ChatView call site), `Modelo/Views/ChatView.swift` (header ~296, init params, onAppear)

**Interfaces:**
- Consumes: `ImageService.listModels(server:)`, `ServerKind.canGenerateImages`, `Conversation.imageServerID/imageModelID`.
- Produces: `struct DiscoveredImageModel: Identifiable, Hashable { let server: Server; let model: ImageModel; var id: String { "\(server.id)|\(model.id)" } }`; `ContentView` state `discoveredImages: [DiscoveredImageModel]`, filled in `refreshModels` in the same task group pattern for non-paused servers where `kind.canGenerateImages`; ChatView param `imageModels: [DiscoveredImageModel]`; `ImageModelPicker(models:selection: Binding<DiscoveredImageModel?>)`. That is a compact `Menu` with a `photo` icon, models grouped by server label, a `"None"` item first, and the label showing the model's displayName or `"Image"`.
- Selecting writes `conversation.imageServerID/imageModelID` and `@AppStorage("lastImageServerID")` / `@AppStorage("lastImageModelID")`. On ChatView `onAppear`, if `conversation.imageModelID == nil && conversation.messages.isEmpty`, copy the stored pair in.

- [ ] **Step 1:** Implement. The picker is hidden when `imageModels` is empty.
- [ ] **Step 2:** BUILD; full TEST suite (omit `-only-testing`) → pass.
- [ ] **Step 3:** Manual check with `./scripts/install.sh`. The picker lists models for each configured image server. `/image a red fox` renders an image in the thread on whichever of Unsloth / ComfyUI / OpenRouter is configured. Relaunch → image still there. Stop during a ComfyUI run → nothing appended.
- [ ] **Step 4:** Commit `feat(images): image model picker beside the chat model`.
- [ ] **Step 5: Part 1 checkpoint.** Push the branch, open PR 1 (repo resolved per CLAUDE.md), report the diff size, and **stop for human review** before Part 2.

---

## Part 2 — tool + artifacts

### Task 10: `generate_image` tool

**Files:**
- Create: `Modelo/Services/GenerateImageTool.swift`
- Modify: `Modelo/Views/ChatView.swift` (tool assembly ~1488), `Modelo/Views/MessageRow.swift:41` (tool row)
- Test: `ModeloTests/GenerateImageToolTests.swift`

**Interfaces:**
- Consumes: `ImageService.generate`, `ChatSession.markdownImage(prompt:handle:)`, `ImageReference.handles(in:)`, environment `imageReference`.
- Produces: `struct GenerateImageTool: Tool { init(generate: @escaping @Sendable @MainActor (_ prompt: String, _ size: String?) async throws -> (handle: String, size: String)) }`. Name `generate_image`. Parameters `prompt` (string, required), `size` (string, `"WIDTHxHEIGHT, default 1024x1024"`). `isMutating` false. The result is exactly:
  `Created <handle> (<size>). <markdownImage> — in HTML use <img src="modelo-image:<handle>">.`
- ChatView appends the tool only when `conversation.imageModelID != nil`. The closure calls `imageService.generate(prompt:size:in: conversation)` and returns `(image.handle, ImageRequest(prompt:"", size: size, modelID:"").sizeString)`.
- **Spec deviation:** tool messages render as a plain `ToolCard`, not markdown. So when `message.toolName == "generate_image"`, MessageRow also shows the images for `ImageReference.handles(in: message.content)` below the card (same view as `ModeloImageProvider`).

- [ ] **Step 1:** Write tests: `test_result_text` (stub closure returns `("img-3","1024x1024")` → the exact string above); `test_missingPrompt_throws`; `test_generateError_propagates` (so `ToolRegistry` returns it to the model as text).
- [ ] **Step 2:** `xcodegen generate`, TEST `GenerateImageToolTests` → fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** TEST `GenerateImageToolTests`, `ToolRegistryTests` → pass; BUILD.
- [ ] **Step 5:** Commit `feat(images): generate_image tool for tool-capable models`.

### Task 11: Resolve images in artifacts and exports

**Files:**
- Modify: `Modelo/Views/ArtifactWebView.swift:47` (`ArtifactHTML.document`) and the PNG capture (~164); `Modelo/Views/ArtifactPanel.swift` (preview ~112, `exportArtifact`, `openArtifactInBrowser`, `exportArtifactAsPNG`, `ArtifactCard` context menu)
- Test: `ModeloTests/ArtifactHTMLTests.swift`

**Interfaces:**
- Consumes: `ImageReference.resolveHTML`, environment `imageReference`.
- Produces: `ArtifactHTML.document(for:dark:forExport:images: ImageReference? = nil)` runs `images?.resolveHTML` over `.html` and `.svg` content before wrapping. The three free export functions gain an `images: ImageReference?` parameter. `ArtifactPanel` and `ArtifactCard` read `@Environment(\.imageReference)` and pass it on. The Source tab keeps showing the raw `modelo-image:` text.

- [ ] **Step 1:** Write tests: `test_document_resolvesImageInHTML` (artifact `<img src="modelo-image:img-1">` + reference → output contains `data:image/png;base64,` and no `modelo-image:`); `test_document_withoutReference_unchanged`.
- [ ] **Step 2:** TEST `ArtifactHTMLTests` → fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** TEST → pass; BUILD.
- [ ] **Step 5:** Commit `feat(images): inline generated images into HTML artifacts and exports`.

### Task 12: Smoke + PR 2

- [ ] **Step 1:** Full TEST suite → pass.
- [ ] **Step 2:** `./scripts/install.sh`, then the spec's three smokes. Each one ends with Export File… → open the `.html` in Safari with the image embedded:
  1. Unsloth Studio: `/image`, then a chat model builds a page using it.
  2. ComfyUI with an SDXL checkpoint.
  3. OpenRouter with a Gemini image model.
  Also: a tool-capable model calls `generate_image` itself and uses the result in an artifact.
- [ ] **Step 3:** Push and open PR 2. Record smoke results in the PR body, including any backend that failed.

---

**Known gaps (not in the spec, left out on purpose):** Markdown export (`/export`) keeps raw `modelo-image:` links. The network scanner won't auto-discover ComfyUI, because it probes `/v1/models`. Generic Cloud API image pickers list every model the API returns, since it has no image filter.
