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
    /// Called on the main actor when a turn finishes replying normally (not after a
    /// user stop or a transport error). The owning view uses it to post a completion
    /// notification when the user isn't watching this chat.
    var onTurnCompleted: (() -> Void)?
    /// Set while a mutating tool call is waiting on the user's approval; the chat view
    /// observes this and shows an approval card. `resume` continues the paused turn.
    var pendingApproval: PendingApproval?

    /// Default cap on agentic tool rounds per turn, used when a session doesn't
    /// specify one. Mirrors the `globalMaxToolRounds` UserDefaults default.
    static let defaultMaxToolRounds = 5
    /// Max agentic tool rounds this turn may run before the loop stops with a
    /// notice. Configurable per session and seeded from the global default
    /// (Settings ▸ Tools); the owning view keeps it in sync with the setting.
    var maxToolRounds: Int
    /// Above this many registered tools, switch to progressive disclosure.
    static let progressiveThreshold = 8
    /// How many relevant tools to pre-select for the model each turn (progressive mode).
    static let preselectLimit = 6
    /// Tools surfaced via find_tools during this turn — callable in later rounds.
    private var revealedTools: Set<String> = []

    /// What the user chose for a pending mutating tool call.
    enum ApprovalDecision: Sendable { case deny, once, session }

    /// A mutating tool call paused for confirmation (file/shell tools).
    struct PendingApproval: Identifiable {
        let id = UUID()
        let toolName: String
        let preview: ToolApprovalPreview
        let resume: @MainActor (ApprovalDecision) -> Void
    }

    /// Tools the user approved for the remainder of this chat session ("approve for
    /// session"), so they run without prompting again until the chat is reopened.
    private var sessionApprovedTools: Set<String> = []

    /// Resolve the pending approval with the user's decision (from the approval card).
    func respondToApproval(_ decision: ApprovalDecision) {
        let pending = pendingApproval
        pendingApproval = nil
        pending?.resume(decision)
    }

    /// Suspend until the user approves/denies a mutating tool call. Returns whether to
    /// proceed, and remembers session-wide approvals so we don't ask again.
    private func requestApproval(toolName: String, preview: ToolApprovalPreview) async -> Bool {
        if sessionApprovedTools.contains(toolName) { return true }
        let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
            pendingApproval = PendingApproval(toolName: toolName, preview: preview) { cont.resume(returning: $0) }
        }
        if decision == .session { sessionApprovedTools.insert(toolName) }
        return decision != .deny
    }

    private let client: any ChatProvider
    private let context: ModelContext
    private let recorder: UsageRecorder
    private let keychain: KeychainStore
    private let registry: ToolRegistry
    /// Appended to every request's system prompt (e.g. the artifact instructions, §2.4).
    private let systemSuffix: String?
    /// The best-effort title run, tracked so it can be cancelled when the view
    /// goes away (e.g. the user switches conversations mid-titling).
    private var titleTask: Task<Void, Never>?

    init(client: any ChatProvider, context: ModelContext, recorder: UsageRecorder,
         keychain: KeychainStore = KeychainStore(),
         registry: ToolRegistry = ToolRegistry([]),
         systemSuffix: String? = nil,
         maxToolRounds: Int = defaultMaxToolRounds) {
        self.client = client
        self.context = context
        self.recorder = recorder
        self.keychain = keychain
        self.registry = registry
        self.systemSuffix = systemSuffix
        self.maxToolRounds = maxToolRounds
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
        // Global tools toggle (Settings ▸ Tools); defaults on when unset.
        let globalToolsEnabled = UserDefaults.standard.object(forKey: "toolsGloballyEnabled") as? Bool ?? true
        let toolsActive = globalToolsEnabled && modelSupportsTools && conversation.toolsEnabled && !registry.isEmpty
        // Progressive disclosure (large tool sets): show only the most relevant tools for
        // this request + a find_tools meta-tool, so a small model isn't drowned in specs.
        let progressive = toolsActive && registry.count > Self.progressiveThreshold
        let queryText = conversation.activePath().last { $0.role == .user }?.content ?? ""
        revealedTools.removeAll()

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
                let toolSpecs = activeToolSpecs(active: toolsActive, progressive: progressive, query: queryText)
                let system = [wire.system, systemSuffix]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                let stream = client.streamChat(
                    endpoint: endpoint, modelID: conversation.modelID,
                    messages: wire.messages.filter(wireKeep),
                    systemPrompt: system,
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

            // Fallback: recover tool calls the model emitted as text (common on local
            // models whose template doesn't produce native tool_calls), and strip the
            // raw markup from what we display.
            if toolCalls.isEmpty && toolsActive {
                let (parsed, cleaned) = ToolCallParser.extract(from: assistant.content)
                if !parsed.isEmpty {
                    toolCalls = parsed
                    assistant.content = cleaned
                }
            }
            if toolCalls.isEmpty { break }   // model produced a final answer

            assistant.toolCallsJSON = toolCalls.json
            for call in toolCalls {
                if Task.isCancelled { break }
                // find_tools is a synthetic meta-tool: reveal the matching tools so they
                // become callable next round, and return their briefs (handled here, not
                // via the registry).
                if call.name == FindToolsTool.toolName {
                    appendToolResult(revealTools(matching: call.arguments), call: call, in: conversation)
                    continue
                }
                // Mutating tools (write/edit/bash) pause for the user's approval.
                if let preview = registry.approvalPreview(name: call.name, argumentsJSON: call.arguments) {
                    let approved = await requestApproval(toolName: call.name, preview: preview)
                    if Task.isCancelled { break }
                    if !approved {
                        appendToolResult("The user declined to run \(call.name).", call: call, in: conversation)
                        continue
                    }
                }
                let result = await registry.execute(name: call.name, argumentsJSON: call.arguments)
                appendToolResult(result, call: call, in: conversation)
            }
            try? context.save()

            round += 1
            if round >= maxToolRounds {
                errorText = "Reached the tool-call limit (\(maxToolRounds)) for this turn."
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

        // The reply landed — let the view surface a notification if the user has
        // moved on to another chat or app (reached only on normal completion).
        onTurnCompleted?()
    }

    /// Cancels the in-flight title run, if any. Called when the owning view goes
    /// away so a best-effort title never outlives its conversation.
    func cancelPendingWork() {
        titleTask?.cancel()
        titleTask = nil
        // Release a turn paused on an approval prompt so its continuation can't leak.
        respondToApproval(.deny)
    }

    /// Tool specs to offer this round: nil when inactive; the full set in normal mode;
    /// or a relevance-pre-selected subset ∪ already-revealed tools + find_tools when the
    /// registry is large (progressive disclosure).
    private func activeToolSpecs(active: Bool, progressive: Bool, query: String) -> [ToolSpec]? {
        guard active else { return nil }
        guard progressive else { return registry.specs() }
        let preselected = ToolSelector.select(catalog: registry.catalog(), query: query, limit: Self.preselectLimit)
        let names = Set(preselected).union(revealedTools)
        return registry.specs(named: names) + [ToolSpec(FindToolsTool())]
    }

    /// Handle a find_tools call: record the matching tools as revealed (so they become
    /// callable next round) and return their briefs for the model.
    private func revealTools(matching argumentsJSON: String) -> String {
        struct Q: Decodable { let query: String }
        let query = (try? JSONDecoder().decode(Q.self, from: Data(argumentsJSON.utf8)))?.query ?? ""
        let matches = ToolSelector.select(catalog: registry.catalog(), query: query, limit: 8)
            .filter { $0 != FindToolsTool.toolName }
        revealedTools.formUnion(matches)
        let briefs = registry.catalog()
            .filter { matches.contains($0.name) }
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
        return briefs.isEmpty ? "No matching tools found." : "These tools are now available to call:\n\(briefs)"
    }

    /// Append a tool's result onto the active path as a `.tool` message.
    private func appendToolResult(_ content: String, call: ToolCall, in conversation: Conversation) {
        let toolMsg = Message(role: .tool, content: content)
        toolMsg.toolCallID = call.id
        toolMsg.toolName = call.name
        conversation.appendToPath(toolMsg)
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
        _ = await performCompaction(conversation, server: server)
    }

    /// Outcome of a manual `/compact`.
    enum CompactionOutcome: Equatable { case compacted(turns: Int), nothingToCompact, failed }

    /// Force-summarize older turns now (manual `/compact`), ignoring the auto threshold.
    func compact(_ conversation: Conversation, server: Server) async -> CompactionOutcome {
        await performCompaction(conversation, server: server)
    }

    /// Shared summarization: fold everything except the most recent `compactKeepRecent`
    /// turns of the active path into `conversation.summary` via a separate model run.
    @discardableResult
    private func performCompaction(_ conversation: Conversation, server: Server) async -> CompactionOutcome {
        let path = conversation.activePath().filter(wireKeep)
        let toSummarize = path.dropLast(conversation.compactKeepRecent ?? 8)
        guard let cutoff = toSummarize.last else { return .nothingToCompact }

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
                if Task.isCancelled { return .failed }
                if case .delta(let t) = event { raw += t }
            }
        } catch {
            return .failed  // best-effort; leave the conversation uncompacted
        }

        let summary = ChatSession.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, conversation.modelContext != nil else { return .failed }
        conversation.summary = summary
        conversation.summaryThrough = cutoff
        try? context.save()
        return .compacted(turns: toSummarize.count)
    }

    /// Drops a leading `<think>…</think>` reasoning block (reasoning models emit one
    /// before the answer). Shared by titling, compaction, and export — pure, so
    /// `nonisolated` to call off the main actor.
    nonisolated static func stripReasoning(_ raw: String) -> String {
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
        // Reasoning models (qwen3, deepseek-r, …) emit a think block first.
        var s = stripReasoning(raw)
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
