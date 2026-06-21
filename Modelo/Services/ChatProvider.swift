import Foundation

/// Events yielded by a streaming chat completion.
enum StreamEvent: Equatable {
    case delta(String)
    case usage(promptTokens: Int, completionTokens: Int)
    case toolCalls([ToolCall])
}

/// One assembled tool call from the stream. Codable so it persists in
/// `Message.toolCallsJSON` and reconstructs for re-sending.
struct ToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String   // raw JSON string the model produced
}

extension Array where Element == ToolCall {
    /// JSON for persistence in `Message.toolCallsJSON`.
    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension ToolCall {
    static func decodeList(_ json: String) -> [ToolCall]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ToolCall].self, from: data)
    }
}

/// The content field of a wire message: either a plain string (text-only) or an
/// array of content blocks (used for vision messages with image attachments).
enum WireContent: Encodable, Equatable {
    case text(String)
    case blocks([WireContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):   try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }
}

/// A single content block in a vision-capable message (OpenAI format).
struct WireContentBlock: Encodable, Equatable {
    let type: String
    let text: String?
    let image_url: WireImageURL?

    static func text(_ s: String) -> WireContentBlock {
        WireContentBlock(type: "text", text: s, image_url: nil)
    }

    static func imageURL(_ url: String) -> WireContentBlock {
        WireContentBlock(type: "image_url", text: nil, image_url: WireImageURL(url: url))
    }
}

struct WireImageURL: Encodable, Equatable {
    let url: String
}

/// OpenAI-compatible chat message on the wire. Optional fields are omitted when
/// nil (synthesized `encodeIfPresent`), so plain/user/assistant/tool all share one type.
struct WireMessage: Encodable, Equatable {
    let role: String
    let content: WireContent?
    let tool_calls: [WireToolCall]?
    let tool_call_id: String?

    /// Convenience init for plain-text messages (all existing call sites).
    init(role: String, content: String?, toolCalls: [WireToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = toolCalls
        self.tool_call_id = toolCallID
    }

    /// Init for vision messages carrying mixed text + image content blocks.
    init(role: String, blocks: [WireContentBlock], toolCalls: [WireToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = .blocks(blocks)
        self.tool_calls = toolCalls
        self.tool_call_id = toolCallID
    }
}

struct WireToolCall: Encodable, Equatable {
    let id: String
    let type: String
    let function: Fn

    init(id: String, function: Fn) {
        self.id = id
        self.type = "function"
        self.function = function
    }

    struct Fn: Encodable, Equatable {
        let name: String
        let arguments: String
    }
}

/// Error surface for chat backends.
enum ClientError: LocalizedError, Equatable {
    case invalidURL
    case unreachable
    case unsupported
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:         "The server URL is invalid. Check the address in Settings."
        case .unreachable:        "Could not reach LM Studio over Tailscale. Is it running?"
        case .unsupported:        "This operation is only supported on LM Studio servers."
        case .serverError(let m): m
        }
    }
}

/// Generation controls sent with a chat request (§1.4). Every field is optional:
/// `nil` means "don't send it", so a server that rejects an unknown sampling param
/// never sees it. Resolved per turn by overlaying a conversation's overrides on the
/// global defaults; `temperature` falls back to 0.7 at the wire if still unset.
struct SamplingParams: Codable, Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var stop: [String]?

    /// This params' non-nil fields take precedence; everything else falls through
    /// to `base`. Used as `conversationOverride.overlaying(globalDefaults)`.
    func overlaying(_ base: SamplingParams) -> SamplingParams {
        SamplingParams(
            temperature:      temperature      ?? base.temperature,
            topP:             topP             ?? base.topP,
            maxTokens:        maxTokens        ?? base.maxTokens,
            frequencyPenalty: frequencyPenalty ?? base.frequencyPenalty,
            presencePenalty:  presencePenalty  ?? base.presencePenalty,
            stop:             stop             ?? base.stop
        )
    }
}

/// Common interface for chat backends. `baseURL` is threaded through every call
/// so a single client instance serves any registered server.
protocol ChatProvider: AnyObject {
    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel]
    func streamChat(
        endpoint: Endpoint,
        modelID: String,
        messages: [Message],
        systemPrompt: String,
        sampling: SamplingParams,
        tools: [ToolSpec]?
    ) -> AsyncThrowingStream<StreamEvent, Error>
}
