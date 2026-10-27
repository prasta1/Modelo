# Image Generation — Design Spec

**Date:** 2026-10-27  
**Branch:** `feature/image-generation`

---

## Background

Modelo is chat-only: `LMStudioClient` talks to `/chat/completions` across nine `ServerKind`s.
Images exist only as *input* — user-message attachments (`MessageAttachment`, base64 in
`Message.attachmentsJSON`) sent to vision models. HTML artifacts render in a `WKWebView` via
`loadHTMLString(html, baseURL: nil)`, so they cannot reference local files.

---

## Goal

Generate images **inline in chat**, and let an **HTML artifact built in the same conversation
use them**. Two triggers:

- the chat model calls a `generate_image` tool (agentic — "I'll make a hero image, then use it");
- the user types `/image <prompt>` (direct; works with any chat model).

First-pass backends: **OpenRouter**, **OpenAI-style `/v1/images/generations`** (OpenAI,
Together, any Cloud API), **Unsloth Studio** (local), and **ComfyUI** (local).

Success: on each of Unsloth, ComfyUI and OpenRouter, `/image` produces an image in the
thread, a tool-capable chat model can generate an image and use it in an HTML artifact, and
the exported `.html` opens in Safari with the image embedded.

---

## Non-Goals

- **Nous Research.** Its inference API exposes no image endpoint; the same image models are
  reachable through OpenRouter.
- Image editing, img2img, inpainting, or using an attached image as a generation input.
- Exposed steps / CFG / sampler / negative-prompt controls. The tool takes `prompt` and an
  optional `size` only; default `1024x1024`.
- Imported ComfyUI workflows. ComfyUI uses one built-in txt2img graph plus a checkpoint picker
  (covers SD, SDXL and single-file FLUX checkpoints).
- Ollama and Draw Things / A1111 backends.
- Streaming / progressive image previews.

---

## Design

### Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `ImageGenerator` protocol (`Services/ImageGenerator.swift`) | `listModels(endpoint:) async throws -> [ImageModel]`; `generate(_ ImageRequest, endpoint:) async throws -> [Data]` | — |
| `OpenAIImagesClient` | `POST {base}/images/generations` with `response_format: "b64_json"`. Serves `cloudAPI` and `unsloth` | `URLSession` |
| `OpenRouterImagesClient` | `POST /chat/completions` with `modalities: ["image","text"]`, `stream: false`; decodes `choices[0].message.images[].image_url.url` data URLs. Models = OpenRouter catalog filtered to `output_modalities` containing `"image"` | `OpenRouterCatalog` |
| `ComfyUIClient` | Models = `GET /object_info/CheckpointLoaderSimple` checkpoint names. Generate = fill the built-in graph → `POST /prompt` → poll `GET /history/{prompt_id}` → `GET /view?filename=&subfolder=&type=output` | `URLSession` |
| `GeneratedImage` (`Models/GeneratedImage.swift`) | SwiftData `@Model`: `handle` (`img-N`), `prompt`, `modelID`, `createdAt`, `@Attribute(.externalStorage) data: Data`. `Conversation.images` relationship, cascade delete | SwiftData |
| `ImageService` | Resolves the conversation's image server to an adapter, runs it, persists `GeneratedImage` rows, assigns the next per-conversation handle | adapters, `ModelContext` |
| `GenerateImageTool` | `generate_image(prompt, size?)` → `ImageService`; returns a text result naming the handle | `ImageService` |
| `ImageReference` (resolver) | Rewrites `modelo-image:img-N` to `data:<mime>;base64,…` for one conversation; missing handle → placeholder | `GeneratedImage` |

`ImageRequest` = `{ prompt, size (WxH), modelID, seed? }`. `ImageModel` = `{ id, displayName }`.

### Changes to existing code

- **`ServerKind`**: add `.comfyUI` (default port 8188, no key) and `.unsloth` (default port
  8888, bearer key `sk-unsloth-…`). Both `isLocal == true`. The compiler flags the 12
  exhaustive `switch`es over `kind`.
  - `.comfyUI` is **image-only**: excluded from the chat model picker, chat model fetching and
    the `/v1/models` reachability probe. Its reachability probe is `GET /system_stats`.
  - `.unsloth` is **chat + image**, OpenAI-compatible `/v1` for chat (same wire shape as
    `llamaCpp`, but with bearer auth).
- **`Conversation`**: add `imageServerID: UUID?` and `imageModelID: String?`, plus the
  `images` relationship. The schema is unversioned, so this is an automatic lightweight
  migration.
- **`ModeloApp` schema**: add `GeneratedImage.self`.
- **`SlashParser`**: add `.image(String)` (aliases `image`, `img`), with a suggestion entry.
- **`ChatView` tool assembly** (~line 1500): append `GenerateImageTool` only when the
  conversation has an image model set.
- **Image model picker**: a compact control beside the chat model picker; lists image models
  from all servers that can generate images (`openRouter`, `cloudAPI`, `unsloth`, `comfyUI`).
  New conversations default to the last-used pair (stored in `@AppStorage`).
- **`ArtifactWebView.document(for:dark:forExport:)`**: run the resolver over HTML before
  rendering and exporting.
- **`MessageRow` markdown**: a MarkdownUI image provider for the `modelo-image` scheme.
- **HTTP error decoding**: move `HTTPErrorBody` and the 401/403/429 classification out of
  `LMStudioClient` into a shared `HTTPError.message(status:headers:body:)` used by the chat
  client and all three image clients.

### Data flow

**One reference mechanism everywhere.** Images are referenced as `modelo-image:img-N` —
markdown `![…](modelo-image:img-3)` in message bubbles, `<img src="modelo-image:img-3">` in
HTML artifacts. Renderers resolve the handle against the conversation's `GeneratedImage`
rows. No message↔image ownership bookkeeping; a dangling handle renders a "missing image"
placeholder.

**Tool path:**
1. The model calls `generate_image({"prompt": …, "size": "1024x1024"})`.
2. `ImageService` generates, saves `GeneratedImage(handle: "img-3")`.
3. The tool returns:
   `Created img-3 (1024x1024). ![<prompt>](modelo-image:img-3) — in HTML use <img src="modelo-image:img-3">.`
   Stored as the normal tool message, so the image renders in the thread.
4. The model writes an HTML artifact using `modelo-image:img-3`; the artifact panel and
   export inline it as a data URI.

**`/image <prompt>` path:**
1. `ChatSession` persists the user message, calls `ImageService` directly (no chat model).
2. It appends an assistant message `![<prompt>](modelo-image:img-4)`.
3. Later turns see that markdown in history, so "use img-4 in the landing page" works.

**No streaming.** The bubble shows a "Generating image…" spinner. ComfyUI polls every 1 s,
timing out after 5 min.

**Handles** are per conversation and monotonically increasing (`max(existing) + 1`), never
reused after a deletion.

### Built-in ComfyUI graph

A minimal API-format txt2img graph: `CheckpointLoaderSimple` → `CLIPTextEncode` (positive) +
`CLIPTextEncode` (empty negative) → `EmptyLatentImage` (width/height) → `KSampler`
(seed random unless given, 20 steps, CFG 7, `euler`, `normal`) → `VAEDecode` → `SaveImage`
(prefix `modelo`). Stored as a Swift literal; `ComfyUIClient` sets checkpoint, prompt, seed
and size on known node IDs.

### Error handling

- **Shared HTTP classification**: 401/403 → `ClientError.authRequired`; provider
  `{"error":{"message"}}` or `[{"error":…}]` → that message; bare 429 → "Rate limited by the
  provider — try again in Ns." / "…shortly."; otherwise "Server returned HTTP N".
- **Tool path**: errors thrown by `GenerateImageTool` are caught by `ToolRegistry` and returned
  to the model as text, so it can explain or retry. The turn continues.
- **`/image` path**: the error becomes the assistant message's error text, as chat errors do.
- **ComfyUI**: `node_errors` from `/prompt` (e.g. missing checkpoint) → node + reason;
  `status.status_str == "error"` in history → the exception message; 5 min without a result →
  "ComfyUI timed out after 5 min".
- **Stop**: cancels the task and the in-flight request. For ComfyUI also sends
  `POST /interrupt`. This interrupts whatever ComfyUI is currently running, which may be a
  job the user queued elsewhere — accepted.
- **No image in a 200 response** (e.g. an OpenRouter model without image output) →
  "<model> returned no image".
- **No image model set**: `generate_image` is not offered; `/image` replies "Pick an image
  model first."

---

## Testing

Unit tests with `StubURLProtocol` and in-memory SwiftData:

- `OpenAIImagesClient`: request path, body, bearer header; `b64_json` decode; 429 and 400
  (content policy) through the shared classifier.
- `OpenRouterImagesClient`: `modalities` and `stream: false` in the body; data-URL decode
  from `message.images[]`; "returned no image" when absent.
- `ComfyUIClient`: checkpoint parsing from `/object_info`; graph injection (prompt, seed,
  checkpoint, size); `/prompt` → `/history` → `/view` sequence; `node_errors`; error status.
- `ImageService`: handle numbering per conversation; cascade delete with the conversation.
- `ImageReference`: handle → data URI; missing handle → placeholder.
- `SlashParser`: `/image foo` → `.image("foo")`.
- `HTTPError`: existing `LMStudioClient` error tests keep passing after the move.

Manual smoke before merge, each ending with HTML export opened in Safari:

1. Unsloth Studio — `/image`, then a chat model building a page with it.
2. ComfyUI with an SDXL checkpoint.
3. OpenRouter with a Gemini image model.

---

## Size and decomposition

Estimated 1200–1500 lines. If the first pass exceeds ~1500 (AGENTS.md), split into two PRs:

1. Adapters, `GeneratedImage`, new server kinds, image model picker, `/image`.
2. `generate_image` tool, `modelo-image:` resolution in artifacts and export.
