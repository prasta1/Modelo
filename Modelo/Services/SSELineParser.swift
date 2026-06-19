import Foundation

/// Pure parser for a single Server-Sent-Events line from LM Studio's
/// `/v1/chat/completions` stream. Extracted from the network loop so the
/// parsing rules can be unit-tested without any I/O.
enum SSELineParser {
    enum Outcome: Equatable {
        case event(StreamEvent)
        case toolCallDelta([ToolCallFragment])
        case finish(String?)
        case done      // server sent `data: [DONE]`
        case ignore    // keep-alive / blank / empty delta
    }

    /// A streamed piece of a tool call. `arguments` accumulates across fragments
    /// in `LMStudioClient`; `id`/`name` typically arrive only in the first fragment.
    struct ToolCallFragment: Equatable {
        let index: Int
        let id: String?
        let name: String?
        let arguments: String?
    }

    /// Parses one raw line. Throws `ClientError.serverError` for error frames.
    static func parse(_ rawLine: String) throws -> Outcome {
        guard rawLine.hasPrefix("data:") else { return .ignore }
        let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignore }
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else { return .ignore }

        let decoder = JSONDecoder()
        if let chunk = try? decoder.decode(ChatChunk.self, from: data) {
            if let usage = chunk.usage {
                return .event(.usage(promptTokens: usage.prompt_tokens,
                                     completionTokens: usage.completion_tokens))
            }
            let choice = chunk.choices.first
            if let text = choice?.delta.content, !text.isEmpty {
                return .event(.delta(text))
            }
            if let calls = choice?.delta.tool_calls, !calls.isEmpty {
                return .toolCallDelta(calls.map {
                    ToolCallFragment(index: $0.index, id: $0.id,
                                     name: $0.function?.name, arguments: $0.function?.arguments)
                })
            }
            if let reason = choice?.finish_reason {
                return .finish(reason)
            }
            // Frames with only `reasoning_content` (thinking models) carry no content
            // and are intentionally dropped — there is no thinking UI yet.
            return .ignore
        }
        // Not a normal chunk — surface server error frames; ignore anything else.
        if let err = try? decoder.decode(ErrorFrame.self, from: data),
           let msg = err.error?.message, !msg.isEmpty {
            throw ClientError.serverError(msg)
        }
        return .ignore
    }

    // MARK: Wire types
    private struct ChatChunk: Decodable {
        let choices: [Choice]
        let usage: Usage?
        struct Choice: Decodable { let delta: Delta; let finish_reason: String? }
        struct Delta: Decodable {
            let content: String?
            let tool_calls: [ToolCallDelta]?
        }
        struct ToolCallDelta: Decodable {
            let index: Int
            let id: String?
            let function: Fn?
            struct Fn: Decodable { let name: String?; let arguments: String? }
        }
        struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
    }
    private struct ErrorFrame: Decodable {
        let error: ErrorBody?
        struct ErrorBody: Decodable { let message: String? }
    }
}
