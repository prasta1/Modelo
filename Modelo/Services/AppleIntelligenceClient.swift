import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Chat backend for Apple's on-device model (Foundation Models, macOS 26+).
///
/// Unlike every other provider this runs in-process, so `LMStudioClient` forwards
/// `.appleIntelligence` endpoints here instead of making HTTP calls. Every entry
/// point answers "unavailable" below macOS 26, so callers need no `#available`.
///
/// Stateless by design, matching `ChatProvider`: each turn rebuilds a
/// `LanguageModelSession` from the full transcript. Edit, regenerate, branch and
/// trim all rewrite history, so a cached session would need invalidating on each
/// of those paths; at a 4K context the re-read is cheap (see the spec's TTFT gate).
enum AppleIntelligenceClient {
    static let modelID = "apple-on-device"

    /// One loaded, free, tool-less model when available; `[]` otherwise.
    static func models() -> [LMStudioModel] {
        guard isAvailable() else { return [] }
        return [LMStudioModel(
            id: modelID, object: "model", type: "llm",
            arch: nil, quantization: nil, state: "loaded",
            maxContextLength: AppleIntelligenceRequest.contextTokens,
            publisher: "Apple",
            loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
            keepInRam: nil, isFree: true, toolUseSupported: false
        )]
    }

    static func isAvailable() -> Bool { statusMessage() == nil }

    /// True unless the device itself can't run Apple Intelligence. Seeding uses
    /// this, so a Mac with Apple Intelligence merely switched off still gets the
    /// row, with a hint on how to turn it on.
    static func isEligible() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability { return false }
            return true
        }
        #endif
        return false
    }

    /// nil when the model is ready; otherwise why not, worded for the user.
    static func statusMessage() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:                               return nil
            case .unavailable(.deviceNotEligible):         return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings."
            case .unavailable(.modelNotReady):             return "Apple Intelligence is still downloading its model."
            case .unavailable:                             return "Apple Intelligence is unavailable right now."
            }
        }
        #endif
        return "Requires macOS 26 or later."
    }

    /// Loads the model ahead of the first message to cut time to first token.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable() {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    /// Streams a reply as `.delta` events, preceded by a `.notice` when old turns
    /// had to be dropped to fit the context window.
    /// - Parameters:
    ///   - messages: Wire snapshot from `LMStudioClient.wireMessages(_:systemPrompt:)`.
    ///   - sampling: Temperature (clamped to 0...1) and `maxTokens` apply; the rest is ignored.
    static func streamChat(messages: [WireMessage], sampling: SamplingParams)
        -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let task = Task {
                    do {
                        try await stream(messages: messages, sampling: sampling, into: continuation)
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: ClientError.serverError(describe(error)))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: ClientError.serverError("Apple Intelligence requires macOS 26 or later."))
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func stream(messages: [WireMessage], sampling: SamplingParams,
                               into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        let options = AppleIntelligenceRequest.generation(sampling)
        let reserve = AppleIntelligenceRequest.responseReserve(for: sampling)
        guard let request = AppleIntelligenceRequest.make(from: messages, responseReserve: reserve) else {
            throw ClientError.serverError("Nothing to send.")
        }
        if request.droppedTurns > 0 { continuation.yield(.notice(AppleIntelligenceRequest.trimNotice)) }

        let session = LanguageModelSession(model: .default, tools: [], transcript: transcript(for: request))
        let stream = session.streamResponse(
            to: request.prompt,
            options: GenerationOptions(temperature: options.temperature,
                                       maximumResponseTokens: options.maxTokens)
        )
        var previous = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            let delta = AppleIntelligenceRequest.delta(from: previous, to: snapshot.content)
            previous = snapshot.content
            if !delta.isEmpty { continuation.yield(.delta(delta)) }
        }
    }

    /// History as a `Transcript`; the final prompt is passed to `streamResponse` separately.
    @available(macOS 26, *)
    private static func transcript(for request: AppleIntelligenceRequest) -> Transcript {
        func segments(_ text: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: text))] }
        var entries: [Transcript.Entry] = []
        if let instructions = request.instructions {
            entries.append(.instructions(Transcript.Instructions(segments: segments(instructions), toolDefinitions: [])))
        }
        for turn in request.history {
            switch turn {
            case .user(let text):      entries.append(.prompt(Transcript.Prompt(segments: segments(text))))
            case .assistant(let text): entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(text))))
            }
        }
        return Transcript(entries: entries)
    }

    /// Readable text for the framework's errors; the rest fall through as-is.
    @available(macOS 26, *)
    private static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return "This chat is too long for Apple Intelligence's 4K context. Start a new chat."
            case .guardrailViolation, .refusal:
                return "Apple Intelligence declined to answer this."
            default:
                break
            }
        }
        return error.localizedDescription
    }
    #endif
}
