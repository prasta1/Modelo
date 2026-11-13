import XCTest
import SwiftData
@testable import Modelo

/// A ChatProvider that replays one scripted event-list per streamChat call.
final class FakeProvider: ChatProvider {
    let scripts: [[StreamEvent]]
    /// When non-zero, each `.delta` event is delayed by this amount before
    /// being yielded — lets tests simulate decode timing and TTFT.
    let deltaDelay: TimeInterval
    private(set) var callCount = 0
    private(set) var lastTools: [ToolSpec]?
    private(set) var systemPrompts: [String] = []
    private(set) var lastMessages: [Message] = []
    init(scripts: [[StreamEvent]], deltaDelay: TimeInterval = 0) {
        self.scripts = scripts; self.deltaDelay = deltaDelay
    }
    convenience init(events: [StreamEvent], deltaDelay: TimeInterval = 0) {
        self.init(scripts: [events], deltaDelay: deltaDelay)
    }

    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel] { [] }
    func streamChat(endpoint: Endpoint, modelID: String, messages: [Message],
                    systemPrompt: String, sampling: SamplingParams,
                    tools: [ToolSpec]?) -> AsyncThrowingStream<StreamEvent, Error> {
        let events = scripts[min(callCount, scripts.count - 1)]
        callCount += 1
        lastTools = tools
        lastMessages = messages
        systemPrompts.append(systemPrompt)
        let delay = deltaDelay
        return AsyncThrowingStream { continuation in
            if delay > 0 {
                Task {
                    for e in events {
                        if case .delta = e {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        continuation.yield(e)
                    }
                    continuation.finish()
                }
            } else {
                for e in events { continuation.yield(e) }
                continuation.finish()
            }
        }
    }
}

private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echoes input"
    let parameters = JSONSchema(properties: ["text": .init("string")], required: ["text"])
    let reply: String
    func execute(argumentsJSON: String) async throws -> String { reply }
}

/// A mutating tool that pauses for approval like write/edit/bash do.
private struct MutatingEchoTool: Tool {
    let name = "mutate"
    let description = "Pretends to write"
    let parameters = JSONSchema(properties: [:], required: [])
    var isMutating: Bool { true }
    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? {
        ToolApprovalPreview(kind: .write, title: "Write test", detail: "content")
    }
    func execute(argumentsJSON: String) async throws -> String { "MUTATED" }
}

/// A provider whose stream fails immediately, like a server erroring mid-turn.
private final class ThrowingProvider: ChatProvider {
    struct Boom: Error {}
    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel] { [] }
    func streamChat(endpoint: Endpoint, modelID: String, messages: [Message],
                    systemPrompt: String, sampling: SamplingParams,
                    tools: [ToolSpec]?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}

/// Stands in for the Fetch MCP server's tool: approval-gated, granted per server+tool.
private struct FetchLikeTool: Tool {
    let name = "fetch"
    let description = "Fetches a URL"
    let parameters = JSONSchema(properties: [:], required: [])
    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? {
        ToolApprovalPreview(kind: .external, title: "Call Fetch server", detail: argumentsJSON,
                            grantKey: "mcp:Fetch/fetch")
    }
    func execute(argumentsJSON: String) async throws -> String { "PAGE" }
}

@MainActor
final class ChatSessionTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    func test_send_assemblesAssistantReplyAndRecordsUsage() async throws {
        let context = try makeContext()
        let provider = FakeProvider(events: [
            .delta("Hello"), .delta(" world"),
            .usage(promptTokens: 10, completionTokens: 2)
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "Studio", host: "studio")
        context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id)
        context.insert(convo)

        await session.send("Hi there", in: convo, server: server)

        XCTAssertEqual(convo.messages.count, 2)
        let assistant = convo.messages.first { $0.role == .assistant }
        XCTAssertEqual(assistant?.content, "Hello world")
        XCTAssertEqual(assistant?.tokenCount, 2)

        let usage = try context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.completionTokens, 2)
        XCTAssertEqual(usage.first?.serverLabel, "Studio")

        XCTAssertEqual(convo.contextTokensUsed, 12)
        XCTAssertFalse(session.isStreaming)
    }

    func test_regenerate_forksSiblingAssistantBranch() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.delta("First"), .usage(promptTokens: 10, completionTokens: 1)],
            [.delta("Second"), .usage(promptTokens: 10, completionTokens: 1)],
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("Hi", in: convo, server: server)
        let firstAssistant = try XCTUnwrap(convo.activePath().last)
        XCTAssertEqual(firstAssistant.content, "First")

        await session.regenerate(firstAssistant, in: convo, server: server)

        // A new assistant sibling under the same user parent; the active path now
        // shows it, and the original turn is preserved on its own branch.
        XCTAssertEqual(convo.activePath().map(\.content), ["Hi", "Second"])
        XCTAssertEqual(firstAssistant.content, "First")
        XCTAssertEqual(firstAssistant.siblings.count, 2)
        XCTAssertTrue(firstAssistant.parent === convo.activePath().last?.parent)
        XCTAssertEqual(convo.messages.count, 3)   // user + two assistant branches
    }

    func test_cleanTitle_normalizesModelOutput() {
        XCTAssertEqual(ChatSession.cleanTitle("Hello world"), "Hello world")
        XCTAssertEqual(ChatSession.cleanTitle("  \"Quoted Title\"  "), "Quoted Title")
        XCTAssertEqual(ChatSession.cleanTitle("A Title."), "A Title")
        // Reasoning models emit a think block before the answer.
        XCTAssertEqual(ChatSession.cleanTitle("<think>let me consider…</think>\nFinal Title"),
                       "Final Title")
        // Only the first line is kept.
        XCTAssertEqual(ChatSession.cleanTitle("First Line\nSecond line"), "First Line")
        // Runaway output is capped at 8 words.
        let long = "one two three four five six seven eight nine ten"
        XCTAssertEqual(ChatSession.cleanTitle(long).split(separator: " ").count, 8)
    }

    func test_provisionalTitle_usesFirstLineAndCapsWords() {
        XCTAssertEqual(ChatSession.provisionalTitle(from: "Hello there"), "Hello there")
        XCTAssertEqual(ChatSession.provisionalTitle(from: "Why is the sky blue? Explain.\nSecond line"),
                       "Why is the sky blue? Explain")
        XCTAssertEqual(ChatSession.provisionalTitle(from: "one two three four five six seven eight"),
                       "one two three four five six")
        XCTAssertEqual(ChatSession.provisionalTitle(from: "  \n "), "")
    }

    /// A chat opened with a bare `/skill` has an empty first user message; the
    /// provisional title comes from the first one with text, so that's the opener.
    func test_needsModelTitle_skipsEmptySkillOpener() throws {
        let context = try makeContext()
        let convo = Conversation(modelID: "m", serverID: UUID())
        context.insert(convo)
        let bare = Message(role: .user, content: "")
        bare.skillName = "brainstorming"
        bare.skillInstructions = "Ask one question."
        bare.createdAt = Date(timeIntervalSince1970: 1)
        let next = Message(role: .user, content: "A settings page for skills")
        next.createdAt = Date(timeIntervalSince1970: 2)
        convo.appendToPath(bare)
        convo.appendToPath(next)
        convo.title = ChatSession.provisionalTitle(from: "A settings page for skills")
        XCTAssertTrue(ChatSession.needsModelTitle(convo))
    }

    func test_needsModelTitle_trueOnlyForMissingOrProvisional() throws {
        let context = try makeContext()
        let convo = Conversation(modelID: "qwen3", serverID: UUID())
        context.insert(convo)
        XCTAssertTrue(ChatSession.needsModelTitle(convo))            // no title yet

        convo.appendToPath(Message(role: .user, content: "Tell me about Swift concurrency"))
        convo.title = ChatSession.provisionalTitle(from: "Tell me about Swift concurrency")
        XCTAssertTrue(ChatSession.needsModelTitle(convo))            // stand-in only

        convo.title = "Swift Concurrency Basics"
        XCTAssertFalse(ChatSession.needsModelTitle(convo))           // model or user chose it
    }

    func test_send_keepsProvisionalTitle_whenTitleRunReturnsNothing() async throws {
        let context = try makeContext()
        // First call answers the turn; the second (the title run) yields no text.
        let provider = FakeProvider(scripts: [[.delta("Sure.")], []])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "Studio", host: "studio")
        context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id)
        context.insert(convo)

        await session.send("Explain structured concurrency in Swift please", in: convo, server: server)

        XCTAssertEqual(convo.title, "Explain structured concurrency in Swift")
    }

    func test_send_replacesProvisionalTitle_withModelTitle() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [[.delta("Sure.")], [.delta("Swift Concurrency Basics")]])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "Studio", host: "studio")
        context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id)
        context.insert(convo)

        await session.send("Explain structured concurrency in Swift please", in: convo, server: server)
        // The title run is detached; give it a moment to land.
        for _ in 0..<40 where convo.title != "Swift Concurrency Basics" {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(convo.title, "Swift Concurrency Basics")
    }

    // MARK: lastTurnFailed (sidebar's red "problem" light)

    func test_lastTurnFailed_whenServerOffline() async throws {
        let context = try makeContext()
        let session = ChatSession(client: FakeProvider(events: []), context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "S", host: "s"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)
        await session.send("Hi", in: convo, server: server, serverOnline: false)
        XCTAssertTrue(session.lastTurnFailed)
    }

    func test_lastTurnFailed_whenTheStreamThrows() async throws {
        let context = try makeContext()
        let session = ChatSession(client: ThrowingProvider(), context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "S", host: "s"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)
        await session.send("Hi", in: convo, server: server)
        XCTAssertTrue(session.lastTurnFailed)
    }

    /// A notice reuses the error banner ("earlier messages dropped") but isn't a failure.
    func test_lastTurnFailed_notForANotice_andClearsOnTheNextTurn() async throws {
        let context = try makeContext()
        let session = ChatSession(client: FakeProvider(events: [.notice("Earlier messages were dropped."),
                                                                .delta("ok"),
                                                                .usage(promptTokens: 1, completionTokens: 1)]),
                                  context: context, recorder: UsageRecorder(context: context))
        let server = Server(label: "S", host: "s"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)
        await session.send("Hi", in: convo, server: server, serverOnline: false)
        XCTAssertTrue(session.lastTurnFailed)
        await session.send("Hi again", in: convo, server: server)
        XCTAssertNotNil(session.errorText)          // the notice still shows in the banner…
        XCTAssertFalse(session.lastTurnFailed)      // …but the turn didn't fail
    }

    func test_send_setsErrorMessage_whenServerOffline() async throws {
        let context = try makeContext()
        let session = ChatSession(client: FakeProvider(events: []), context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "MacBook", host: "macbook")
        context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id)
        context.insert(convo)

        await session.send("Hi", in: convo, server: server, serverOnline: false)

        XCTAssertNotNil(session.errorText)
        XCTAssertTrue(convo.messages.allSatisfy { $0.role != .assistant })
    }

    func test_send_runsToolThenContinues() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "echo", arguments: #"{"text":"hi"}"#)])],
            [.delta("Final answer"), .usage(promptTokens: 20, completionTokens: 3)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([EchoTool(reply: "ECHOED")]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id); context.insert(convo)

        await session.send("use a tool", in: convo, server: server, modelSupportsTools: true)

        XCTAssertEqual(convo.messages.count, 4)   // user, assistant(call), tool(result), assistant(final)
        let toolMsg = convo.messages.first { $0.role == .tool }
        XCTAssertEqual(toolMsg?.content, "ECHOED")
        XCTAssertEqual(toolMsg?.toolCallID, "c1")
        XCTAssertTrue(convo.messages.contains { $0.role == .assistant && $0.content == "Final answer" })
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertNotNil(provider.lastTools)
    }

    /// End-to-end memory loop: the model calls save_memory in round 1, and because
    /// the systemSuffix provider re-evaluates each round, round 2's system prompt
    /// already carries the index line for the just-saved memory.
    func test_send_saveMemory_indexAppearsNextRound() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "memory-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "save_memory", arguments:
                #"{"name":"prefers-tabs","description":"Tabs over spaces","content":"Heath prefers tabs."}"#)])],
            [.delta("Noted."), .usage(promptTokens: 20, completionTokens: 2)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([SaveMemoryTool(scopes: [.global], root: root)]),
                                  systemSuffix: { MemoryStore.indexInjection(scopes: [.global], toolsAvailable: $0, root: root) })
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("Remember I prefer tabs", in: convo, server: server, modelSupportsTools: true)

        // The file landed, without any approval pause.
        XCTAssertEqual(MemoryStore.list(.global, root: root).map(\.name), ["prefers-tabs"])
        XCTAssertTrue(convo.messages.contains { $0.role == .tool && $0.content.contains("prefers-tabs") })
        // Round 1 had no memories; round 2's prompt carries the fresh index.
        XCTAssertEqual(provider.systemPrompts.count, 2)
        XCTAssertFalse(provider.systemPrompts[0].contains("## Memory"))
        XCTAssertTrue(provider.systemPrompts[1].contains("- [global] prefers-tabs — Tabs over spaces"))
    }

    func test_send_capsToolRounds() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c", name: "echo", arguments: "{}")])]   // never stops asking
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([EchoTool(reply: "x")]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("loop", in: convo, server: server, modelSupportsTools: true)

        XCTAssertEqual(provider.callCount, session.maxToolRounds)
        XCTAssertNotNil(session.errorText)
    }

    func test_send_respectsConfiguredToolRoundLimit() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c", name: "echo", arguments: "{}")])]   // never stops asking
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([EchoTool(reply: "x")]),
                                  maxToolRounds: 2)
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("loop", in: convo, server: server, modelSupportsTools: true)

        // Stops after exactly the configured number of rounds, not the default.
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertNotNil(session.errorText)
    }

    func test_init_defaultsToolRoundsToGlobalDefault() {
        let context = try! makeContext()
        let session = ChatSession(client: FakeProvider(events: []), context: context,
                                  recorder: UsageRecorder(context: context))
        XCTAssertEqual(session.maxToolRounds, ChatSession.defaultMaxToolRounds)
    }

    // MARK: YOLO mode

    /// Spin the main actor until the session pauses on an approval (or fail).
    private func waitForPendingApproval(in session: ChatSession) async throws {
        for _ in 0..<1000 {
            if session.pendingApproval != nil { return }
            await Task.yield()
        }
        XCTFail("never paused for approval")
    }

    func test_send_yolo_autoApprovesMutatingTool() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "mutate", arguments: "{}")])],
            [.delta("Done"), .usage(promptTokens: 20, completionTokens: 1)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([MutatingEchoTool()]),
                                  yoloMode: true)
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("write it", in: convo, server: server, modelSupportsTools: true)

        // No approval pause, tool ran, turn completed.
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(convo.messages.first { $0.role == .tool }?.content, "MUTATED")
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertNil(session.errorText)
    }

    func test_send_yolo_ignoresRoundCap() async throws {
        let context = try makeContext()
        let toolRound: [StreamEvent] = [.toolCalls([ToolCall(id: "c", name: "echo", arguments: "{}")])]
        let provider = FakeProvider(scripts: [
            toolRound, toolRound, toolRound, toolRound, toolRound,
            [.delta("Final"), .usage(promptTokens: 20, completionTokens: 1)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([EchoTool(reply: "x")]),
                                  maxToolRounds: 2, yoloMode: true)
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("loop", in: convo, server: server, modelSupportsTools: true)

        // Runs well past the configured cap and finishes on the model's terms.
        XCTAssertEqual(provider.callCount, 6)
        XCTAssertNil(session.errorText)
    }

    func test_yolo_flipOnMidTurn_releasesPendingApproval() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "mutate", arguments: "{}")])],
            [.delta("Done"), .usage(promptTokens: 20, completionTokens: 1)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([MutatingEchoTool()]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        let turn = Task { await session.send("write it", in: convo, server: server, modelSupportsTools: true) }
        try await waitForPendingApproval(in: session)

        session.yoloMode = true
        await turn.value

        // The pending approval was released as a one-off grant and the tool ran.
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(convo.messages.first { $0.role == .tool }?.content, "MUTATED")
        XCTAssertNil(session.errorText)
    }

    func test_send_multiRoundUsageAccumulatesCumulatively() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "echo", arguments: "{\"text\":\"hi\"}")]), .usage(promptTokens: 40, completionTokens: 50)],
            [.delta("Final"), .usage(promptTokens: 60, completionTokens: 130)],
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([EchoTool(reply: "X")]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id); context.insert(convo)

        await session.send("use a tool", in: convo, server: server, modelSupportsTools: true)

        let usage = try context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(usage.count, 1)
        // Round 1 reported 50 completion tokens; round 2 reported 130 (cumulative).
        // The UsageRecord should store the highest value (130), not the summed (180).
        XCTAssertEqual(usage.first?.completionTokens, 130)
        let assistant = convo.messages.first { $0.role == .assistant && $0.content == "Final" }
        XCTAssertEqual(assistant?.tokenCount, 130)
    }

    func test_tps_recordsDecodeAndEndToEnd() async throws {
        let context = try makeContext()
        // Each .delta is delayed 0.5s, so:
        //   start = T0
        //   first .delta at T0+0.5 → firstTokenAt (0.5s TTFT)
        //   second .delta at T0+1.0
        //   .usage at T0+1.0
        //
        // Old formula (total elapsed):  ~1.0s → 4/1.0 ≈ 4 tok/s
        // New formula (decode only):    ~0.5s → 4/0.5 ≈ 8 tok/s
        // Assert > 6: only decode-only timing can satisfy this.
        let provider = FakeProvider(events: [
            .delta("Hello"), .delta(" world"),
            .usage(promptTokens: 10, completionTokens: 4)
        ], deltaDelay: 0.5)
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "Test", host: "t")
        context.insert(server)
        let convo = Conversation(modelID: "qwen3", serverID: server.id)
        context.insert(convo)

        await session.send("Hi", in: convo, server: server)

        let usage = try context.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(usage.count, 1)
        let record = try XCTUnwrap(usage.first)
        XCTAssertEqual(record.completionTokens, 4)
        // TTFT should reflect the ~0.5s delay before the first token.
        XCTAssertGreaterThan(record.ttftMillis, 300)
        // Decode-only TPS: 4 tokens over ~0.5s (first token → finish).
        // Old total-time formula would give ~4 tok/s; decode-only gives ~8.
        XCTAssertGreaterThan(record.tokensPerSecond, 6)

        // The assistant message carries the same compute metrics.
        let assistant = try XCTUnwrap(convo.messages.first { $0.role == .assistant })
        XCTAssertEqual(assistant.content, "Hello world")
        XCTAssertEqual(assistant.tokenCount, 4)
        XCTAssertGreaterThan(try XCTUnwrap(assistant.tokensPerSecond), 6)
        // End-to-end folds the ~0.5s TTFT back in: 4 tokens over ~1.0s ≈ 4 tok/s.
        let e2e = try XCTUnwrap(assistant.endToEndTokensPerSecond)
        XCTAssertLessThan(e2e, 6)
        XCTAssertLessThan(e2e, try XCTUnwrap(assistant.tokensPerSecond))
    }

    /// Long research: approving an MCP tool (Fetch) for the session lets its later calls
    /// in the same chat run without another click.
    func test_sessionGrant_forMCPTool_skipsLaterPrompts() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "fetch", arguments: #"{"url":"https://a.example"}"#)])],
            [.toolCalls([ToolCall(id: "c2", name: "fetch", arguments: #"{"url":"https://b.example"}"#)])],
            [.delta("Done"), .usage(promptTokens: 20, completionTokens: 1)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([FetchLikeTool()]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        let turn = Task { await session.send("research", in: convo, server: server, modelSupportsTools: true) }
        try await waitForPendingApproval(in: session)
        session.respondToApproval(.session)
        await turn.value

        XCTAssertNil(session.pendingApproval)                       // never asked a second time
        XCTAssertEqual(convo.messages.filter { $0.role == .tool }.count, 2)
        // `messages` isn't stored in time order, so look for the final reply directly.
        XCTAssertTrue(convo.messages.contains { $0.role == .assistant && $0.content == "Done" })
    }

    func test_withoutYolo_mutatingToolStillPrompts() async throws {
        let context = try makeContext()
        let provider = FakeProvider(scripts: [
            [.toolCalls([ToolCall(id: "c1", name: "mutate", arguments: "{}")])],
            [.delta("Ok"), .usage(promptTokens: 20, completionTokens: 1)]
        ])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context),
                                  registry: ToolRegistry([MutatingEchoTool()]))
        let server = Server(label: "Studio", host: "studio"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        let turn = Task { await session.send("write it", in: convo, server: server, modelSupportsTools: true) }
        try await waitForPendingApproval(in: session)

        session.respondToApproval(.deny)
        await turn.value

        XCTAssertEqual(convo.messages.first { $0.role == .tool }?.content,
                       "The user declined to run mutate.")
    }

    /// A bare `/skill` has no typed text but must still be saved and sent.
    func test_send_bareSkill_isSentAndKept() async throws {
        let context = try makeContext()
        let provider = FakeProvider(events: [.delta("ok"), .usage(promptTokens: 1, completionTokens: 1)])
        let session = ChatSession(client: provider, context: context,
                                  recorder: UsageRecorder(context: context))
        let server = Server(label: "S", host: "s"); context.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id); context.insert(convo)

        await session.send("", in: convo, server: server,
                           skill: AgentSkill(name: "s", description: "", instructions: "Do X."))

        let user = try XCTUnwrap(convo.messages.first { $0.role == .user })
        XCTAssertEqual(user.skillName, "s")
        XCTAssertEqual(user.skillInstructions, "Do X.")
        let wire = LMStudioClient.wireMessages(provider.lastMessages, systemPrompt: "")
        XCTAssertTrue(wire.contains { if case .text(let t)? = $0.content { t.contains("Do X.") } else { false } })
    }
}
