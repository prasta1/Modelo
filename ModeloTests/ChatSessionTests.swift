import XCTest
import SwiftData
@testable import Modelo

/// A ChatProvider that replays one scripted event-list per streamChat call.
final class FakeProvider: ChatProvider {
    let scripts: [[StreamEvent]]
    private(set) var callCount = 0
    private(set) var lastTools: [ToolSpec]?
    init(scripts: [[StreamEvent]]) { self.scripts = scripts }
    convenience init(events: [StreamEvent]) { self.init(scripts: [events]) }

    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel] { [] }
    func streamChat(endpoint: Endpoint, modelID: String, messages: [Message],
                    systemPrompt: String, temperature: Double,
                    tools: [ToolSpec]?) -> AsyncThrowingStream<StreamEvent, Error> {
        let events = scripts[min(callCount, scripts.count - 1)]
        callCount += 1
        lastTools = tools
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
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

        XCTAssertEqual(provider.callCount, ChatSession.maxToolRounds)
        XCTAssertNotNil(session.errorText)
    }
}
