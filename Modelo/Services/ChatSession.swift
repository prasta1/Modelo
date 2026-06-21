import Foundation
import SwiftData

/// Drives one active streaming turn: appends the user message, streams the
/// assistant reply token-by-token, then writes a UsageRecord. Owned by the
/// chat view via @State; observe `isStreaming` / `errorText` for UI.
@Observable
@MainActor
final class ChatSession {
    private(set) var isStreaming = false
    var errorText: String?

    static let maxToolRounds = 5

    private let client: any ChatProvider
    private let context: ModelContext
    private let recorder: UsageRecorder
    private let keychain: KeychainStore
    private let registry: ToolRegistry
    /// The best-effort title run, tracked so it can be cancelled when the view
    /// goes away (e.g. the user switches conversations mid-titling).
    private var titleTask: Task<Void, Never>?

    init(client: any ChatProvider, context: ModelContext, recorder: UsageRecorder,
         keychain: KeychainStore = KeychainStore(),
         registry: ToolRegistry = ToolRegistry([])) {
        self.client = client
        self.context = context
        self.recorder = recorder
        self.keychain = keychain
        self.registry = registry
    }

    /// Sends `text` in `conversation`, routed to `server`. Runs the agentic loop:
    /// streams a reply, and if the model requests tools, executes them and re-streams
    /// (capped at `maxToolRounds`) until a final answer. Pass `serverOnline:false` to
    /// short-circuit with an inline error; `modelSupportsTools` gates tool offering.
    /// Pass `replacing:` an existing user message to fork a new sibling branch under
    /// the same parent (edit & resend); otherwise the new turn extends the active
    /// path linearly. Editing a root turn falls back to a linear append (§1.2 keeps
    /// root branching out of scope).
    func send(_ text: String, attachments: [MessageAttachment] = [],
              in conversation: Conversation, server: Server,
              serverOnline: Bool = true, modelSupportsTools: Bool = false,
              sampling: SamplingParams = SamplingParams(),
              contextWindow: Int = 0,
              replacing edited: Message? = nil) async {
        errorText = nil
        guard serverOnline else {
            errorText = "\(server.label) is offline — can't send right now."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let userMsg = Message(role: .user, content: trimmed)
        if !attachments.isEmpty { userMsg.attachmentsJSON = attachments.json }
        if let edited, edited.parent != nil {
            conversation.branch(userMsg, asSiblingOf: edited)
        } else {
            conversation.appendToPath(userMsg)
        }
        try? context.save()

        await runTurn(in: conversation, server: server,
                      modelSupportsTools: modelSupportsTools, sampling: sampling,
                      contextWindow: contextWindow,
                      firstAssistant: nil, titleOnFirstExchange: true)
    }

    /// Re-runs an assistant turn as a new sibling branch under the same parent
    /// (§1.3). The previous turn is preserved on its own branch and stays reachable
    /// via the ◀ k/n ▶ control.
    func regenerate(_ target: Message, in conversation: Conversation, server: Server,
                    serverOnline: Bool = true, modelSupportsTools: Bool = false,
                    sampling: SamplingParams = SamplingParams(),
                    contextWindow: Int = 0) async {
        errorText = nil
        guard serverOnline else {
            errorText = "\(server.label) is offline — can't regenerate right now."
            return
        }
        guard target.role == .assistant else { return }

        // Fork an empty assistant sibling and stream into it; its active path walks
        // back through the same user parent, so the model re-answers the same prompt.
        let fresh = Message(role: .assistant, content: "")
        conversation.branch(fresh, asSiblingOf: target)
        try? context.save()

        await runTurn(in: conversation, server: server,
                      modelSupportsTools: modelSupportsTools, sampling: sampling,
                      contextWindow: contextWindow,
                      firstAssistant: fresh, titleOnFirstExchange: false)
    }

    /// The shared agentic streaming loop, run into the conversation's active path:
    /// streams an assistant reply, executes any requested tools and re-streams (capped
    /// at `maxToolRounds`), then records telemetry. `firstAssistant`, when non-nil, is
    /// streamed into on the first round (regenerate passes its pre-branched sibling);
    /// otherwise a fresh assistant is appended each round. The user turn must already
    /// be on the active path.
    private func runTurn(in conversation: Conversation, server: Server,
                         modelSupportsTools: Bool,
                         sampling: SamplingParams,
                         contextWindow: Int,
                         firstAssistant: Message?,
                         titleOnFirstExchange: Bool) async {
        isStreaming = true
        defer { isStreaming = false }

        // Summarize older turns first if the chat is near the window (§1.5).
        await compactIfNeeded(conversation, server: server, contextWindow: contextWindow)

        let endpoint = Endpoint(server: server, keychain: keychain)
        let toolsActive = modelSupportsTools && conversation.toolsEnabled && !registry.isEmpty
        let toolSpecs = toolsActive ? registry.specs() : nil

        let start = Date()
        var firstTokenAt: Date?
        var lastPromptTokens = 0
        var lastCompletionTokens = 0
        var totalCompletionTokens = 0
        var round = 0
        var lastAssistant: Message?
        var pendingAssistant = firstAssistant

        while true {
            // User-initiated stop before a new round: don't start another stream.
            if Task.isCancelled { break }
            let assistant: Message
            if let supplied = pendingAssistant {
                // Regenerate's pre-branched sibling is the active leaf already.
                assistant = supplied
                pendingAssistant = nil
            } else {
                assistant = Message(role: .assistant, content: "")
                conversation.appendToPath(assistant)
            }
            lastAssistant = assistant
            try? context.save()

            var toolCalls: [ToolCall] = []
            var roundCompletion = 0
            do {
                // Active root→leaf path with any compaction applied: the system prompt
                // carries the summary, and only post-cutoff turns are sent (§1.5). The
                // just-appended empty assistant is dropped by wireKeep.
                let wire = conversation.wireContext()
                let stream = client.streamChat(
                    endpoint: endpoint, modelID: conversation.modelID,
                    messages: wire.messages.filter(wireKeep),
                    systemPrompt: wire.system,
                    sampling: sampling,
                    tools: toolSpecs)
                // Buffer incoming tokens and flush to the observable property at ~20fps
                // rather than on every character. This prevents SwiftUI from scheduling a
                // full layout pass for each token, which was the primary source of latency.
                var pendingContent = ""
                var lastFlushDate: Date? = nil
                for try await event in stream {
                    // User-initiated stop (the wrapping Task was cancelled): keep what
                    // streamed so far and stop consuming. Dropping the stream iterator
                    // triggers the client's `onTermination`, cancelling the network task.
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let t):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        pendingContent += t
                        let now = Date()
                        // Flush immediately on the first token (preserves TTFT), then
                        // throttle to ~20fps to batch subsequent tokens into fewer redraws.
                        let shouldFlush = lastFlushDate == nil
                            || now.timeIntervalSince(lastFlushDate!) >= 0.05
                        if shouldFlush {
                            assistant.content += pendingContent
                            pendingContent = ""
                            lastFlushDate = now
                        }
                    case .usage(let p, let c):
                        lastPromptTokens = p; roundCompletion = c
                    case .toolCalls(let cs):
                        toolCalls = cs
                    }
                }
                // Flush any tokens buffered since the last 50ms window.
                if !pendingContent.isEmpty {
                    assistant.content += pendingContent
                }
            } catch {
                errorText = (error as? ClientError)?.errorDescription ?? error.localizedDescription
                if assistant.content.isEmpty && assistant.toolCallsJSON == nil {
                    conversation.dropLeaf(assistant)
                    context.delete(assistant)
                }
                try? context.save()
                return
            }

            totalCompletionTokens += roundCompletion
            lastCompletionTokens = roundCompletion

            // Stopped mid-stream: don't execute tools or start another round.
            if Task.isCancelled { break }
            if toolCalls.isEmpty { break }   // model produced a final answer

            assistant.toolCallsJSON = toolCalls.json
            for call in toolCalls {
                let result = await registry.execute(name: call.name, argumentsJSON: call.arguments)
                let toolMsg = Message(role: .tool, content: result)
                toolMsg.toolCallID = call.id
                toolMsg.toolName = call.name
                conversation.appendToPath(toolMsg)
            }
            try? context.save()

            round += 1
            if round >= Self.maxToolRounds {
                errorText = "Reached the tool-call limit (\(Self.maxToolRounds)) for this turn."
                break
            }
        }

        // Stopped mid-stream: persist whatever streamed (drop an empty trailing
        // bubble) and skip telemetry/titling — a partial turn has no meaningful
        // usage frame.
        if Task.isCancelled {
            if let last = lastAssistant, last.content.isEmpty, last.toolCallsJSON == nil {
                conversation.dropLeaf(last)
                context.delete(last)
            }
            try? context.save()
            return
        }

        // tok/s is decode speed: measured from the first token, not from send.
        // Excluding prefill + network round-trip (the TTFT window) matches how
        // LM Studio reports generation rate — folding TTFT in makes a fast model
        // read slow, especially over the network or with a long prompt to prefill.
        let elapsed = Date().timeIntervalSince(firstTokenAt ?? start)
        let tps = UsageMath.tokensPerSecond(completionTokens: totalCompletionTokens, elapsed: elapsed)
        let ttft = UsageMath.millis((firstTokenAt ?? start).timeIntervalSince(start))
        lastAssistant?.tokenCount = totalCompletionTokens
        lastAssistant?.tokensPerSecond = tps
        conversation.contextTokensUsed = lastPromptTokens + lastCompletionTokens
        // Re-encode the active leaf now that the message has a permanent
        // persistentModelID (the id assigned before the first save was temporary),
        // so branch navigation resolves it instead of falling back to date order.
        if let lastAssistant { conversation.activeLeaf = lastAssistant }
        try? context.save()

        recorder.record(
            modelID: conversation.modelID, serverLabel: server.label,
            promptTokens: lastPromptTokens, completionTokens: totalCompletionTokens,
            tokensPerSecond: tps, ttftMillis: ttft
        )

        // On the first exchange, name the chat with a short, separate model run.
        // Detached so it never blocks the input or flips `isStreaming`; best-effort.
        // Skipped on regenerate — a re-run isn't a new exchange.
        if titleOnFirstExchange {
            let isFirstExchange = conversation.messages.filter { $0.role == .user }.count == 1
            if isFirstExchange, (conversation.title ?? "").isEmpty {
                titleTask = Task { await generateTitle(for: conversation, server: server) }
            }
        }
    }

    /// Cancels the in-flight title run, if any. Called when the owning view goes
    /// away so a best-effort title never outlives its conversation.
    func cancelPendingWork() {
        titleTask?.cancel()
        titleTask = nil
    }

    /// Auto-compaction (§1.5): when enabled and the active path's estimated tokens
    /// exceed `compactThreshold × contextWindow`, summarize everything except the most
    /// recent `compactKeep` turns into `conversation.summary` via a separate
    /// non-streaming model run. Best-effort and idempotent-ish — re-summarizes the
    /// whole prefix each time it fires (simpler than incremental; fine for v1).
    private func compactIfNeeded(_ conversation: Conversation, server: Server, contextWindow: Int) async {
        guard conversation.autoCompact, contextWindow > 0 else { return }
        let path = conversation.activePath().filter(wireKeep)
        let estimate = TokenEstimator.estimate(path) + TokenEstimator.estimate(conversation.summary ?? "")
        guard Double(estimate) > (conversation.compactThresholdPct ?? 0.85) * Double(contextWindow) else { return }
        let toSummarize = path.dropLast(conversation.compactKeepRecent ?? 8)
        guard let cutoff = toSummarize.last else { return }

        let transcript = toSummarize
            .map { "\($0.role.rawValue.uppercased()): \($0.content)" }
            .joined(separator: "\n\n")
        let system = """
        You compress conversations. Summarize the transcript into a concise summary \
        that preserves key facts, decisions, names, code, and unresolved questions so \
        the assistant can continue seamlessly. Reply with only the summary.
        """
        let prior = conversation.summary.map { "Existing summary:\n\($0)\n\n---\n\n" } ?? ""
        let prompt = Message(role: .user, content: prior + transcript)

        var raw = ""
        do {
            let stream = client.streamChat(
                endpoint: Endpoint(server: server, keychain: keychain), modelID: conversation.modelID,
                messages: [prompt], systemPrompt: system,
                sampling: SamplingParams(temperature: 0.3), tools: nil)
            for try await event in stream {
                if Task.isCancelled { return }
                if case .delta(let t) = event { raw += t }
            }
        } catch {
            return  // best-effort; leave the conversation uncompacted
        }

        let summary = ChatSession.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, conversation.modelContext != nil else { return }
        conversation.summary = summary
        conversation.summaryThrough = cutoff
        try? context.save()
    }

    /// Drops a leading `<think>…</think>` reasoning block (reasoning models emit one
    /// before the answer). Shared by titling and compaction.
    static func stripReasoning(_ raw: String) -> String {
        guard let r = raw.range(of: "</think>", options: .backwards) else { return raw }
        return String(raw[r.upperBound...])
    }

    /// Asks the same model for a concise title based on the opening user message,
    /// then writes it to `conversation.title`. Silent on failure — the sidebar
    /// falls back to "New Chat" until (and unless) this succeeds.
    private func generateTitle(for conversation: Conversation, server: Server) async {
        let opener = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .first { $0.role == .user }?.content ?? ""
        guard !opener.isEmpty else { return }

        // A transient (un-inserted) prompt — never persisted, just fed to the model.
        let prompt = Message(role: .user, content: String(opener.prefix(600)))
        let system = """
        Generate a short, specific title (3 to 6 words) for a conversation that \
        opens with the following message. Reply with ONLY the title — no quotes, \
        no preamble, no trailing punctuation.
        """

        var raw = ""
        do {
            let stream = client.streamChat(
                endpoint: Endpoint(server: server, keychain: keychain), modelID: conversation.modelID,
                messages: [prompt], systemPrompt: system,
                sampling: SamplingParams(temperature: 0.3),
                tools: nil
            )
            for try await event in stream {
                if case .delta(let t) = event { raw += t }
            }
        } catch {
            return // best-effort; leave untitled
        }

        let title = Self.cleanTitle(raw)
        guard !title.isEmpty else { return }
        // Bail if cancelled or the conversation was deleted mid-run: a deleted
        // @Model loses its `modelContext`, and writing to it would be pointless.
        guard !Task.isCancelled, conversation.modelContext != nil else { return }
        conversation.title = title
        try? context.save()
    }

    /// Normalizes a model's title output: drops any `<think>…</think>` reasoning,
    /// takes the first line, strips wrapping quotes and trailing punctuation, and
    /// caps the length so the sidebar stays tidy.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        // Reasoning models (qwen3, deepseek-r, …) emit a think block first.
        if let r = s.range(of: "</think>", options: .backwards) {
            s = String(s[r.upperBound...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(separator: "\n").first.map(String.init) ?? s
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, ".!?,;:".contains(last) { s.removeLast() }
        let words = s.split(separator: " ")
        if words.count > 8 { s = words.prefix(8).joined(separator: " ") }
        return String(s.prefix(60))
    }

    /// Which persisted messages go on the wire: tool results and assistant tool-call
    /// messages always (even with empty content); plain messages only when non-empty.
    private func wireKeep(_ m: Message) -> Bool {
        if m.role == .tool { return true }
        if m.role == .assistant && m.toolCallsJSON != nil { return true }
        return !m.content.isEmpty
    }
}
