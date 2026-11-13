import Foundation

/// A chat turn reshaped for Apple's on-device model: instructions, alternating
/// history, and the final prompt, trimmed to fit its 4,096-token context.
///
/// Deliberately free of `FoundationModels` types so the mapping, trimming and
/// stream diffing unit-test without the model; `AppleIntelligenceClient` turns
/// this into a `Transcript`.
struct AppleIntelligenceRequest: Equatable {
    enum Turn: Equatable { case user(String), assistant(String) }

    /// Total context of the macOS 26 system model (instructions + prompts + output).
    static let contextTokens = 4096
    /// Room left for the reply when the request doesn't set `maxTokens`.
    static let defaultResponseReserve = 1024
    static let trimNotice = "Earlier messages were dropped to fit Apple Intelligence's 4K context."

    var instructions: String?
    /// Oldest first; excludes the final prompt.
    var history: [Turn]
    var prompt: String
    /// History turns removed to fit the budget.
    var droppedTurns: Int

    /// Builds a request from the OpenAI-shaped wire messages every provider gets.
    ///
    /// Tool traffic (`tool` messages, assistant messages carrying only tool calls)
    /// is skipped: Tier 1 has no tools. Image blocks are dropped and text blocks
    /// kept. Oldest history turns are removed until the estimate fits
    /// `contextTokens - responseReserve`; the instructions and prompt are never cut.
    /// - Parameters:
    ///   - wire: Output of `LMStudioClient.wireMessages(_:systemPrompt:)`.
    ///   - responseReserve: Tokens to leave free for the reply.
    /// - Returns: nil when the last usable message isn't from the user.
    static func make(from wire: [WireMessage], responseReserve: Int) -> AppleIntelligenceRequest? {
        var instructions: String?
        var turns: [Turn] = []
        for message in wire {
            guard let text = text(of: message), !text.isEmpty else { continue }
            switch message.role {
            case "system":    instructions = text
            case "user":      turns.append(.user(text))
            case "assistant": turns.append(.assistant(text))
            default:          continue   // "tool"
            }
        }
        guard case .user(let prompt) = turns.popLast() else { return nil }

        // ponytail: ~4 chars/token heuristic can under-count; the client maps the
        // framework's context-overflow error to a readable message as the backstop.
        let budget = contextTokens - responseReserve
        var cost = TokenEstimator.estimate(instructions ?? "") + TokenEstimator.estimate(prompt)
            + turns.reduce(0) { $0 + estimate($1) }
        var dropped = 0
        while cost > budget, !turns.isEmpty {
            cost -= estimate(turns.removeFirst())
            dropped += 1
        }
        return AppleIntelligenceRequest(instructions: instructions, history: turns,
                                        prompt: prompt, droppedTurns: dropped)
    }

    /// The text to emit for a new cumulative stream snapshot.
    /// - Returns: The part of `current` past `previous`, or "" if `current`
    ///   doesn't extend it (a rewrite can't be expressed as an append).
    static func delta(from previous: String, to current: String) -> String {
        current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : ""
    }

    /// The sampling settings the system model accepts: temperature clamped to its
    /// 0...1 range (Modelo's 0.7 default when unset) and the reply cap, clamped to
    /// half the context. A global Max tokens sized for big local models (4096+)
    /// would otherwise reserve the whole window and trim away all history.
    /// Top-p, penalties and stop sequences have no equivalent and are dropped.
    static func generation(_ s: SamplingParams) -> (temperature: Double, maxTokens: Int?) {
        (min(max(s.temperature ?? 0.7, 0), 1), s.maxTokens.map { min($0, contextTokens / 2) })
    }

    /// Tokens to keep free for the reply: the clamped Max tokens, else the default.
    static func responseReserve(for s: SamplingParams) -> Int {
        generation(s).maxTokens ?? defaultResponseReserve
    }

    private static func text(of message: WireMessage) -> String? {
        guard let content = message.content else { return nil }
        return content.blocks.compactMap(\.text).joined(separator: "\n\n")
    }

    private static func estimate(_ turn: Turn) -> Int {
        switch turn {
        case .user(let s), .assistant(let s): TokenEstimator.estimate(s)
        }
    }
}
