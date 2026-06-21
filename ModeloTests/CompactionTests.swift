import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class CompactionTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self,
                             UsageRecord.self, Persona.self, Folder.self, Preset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func msg(_ role: MessageRole, _ content: String, _ t: TimeInterval) -> Message {
        let m = Message(role: role, content: content)
        m.createdAt = Date(timeIntervalSince1970: t)
        return m
    }

    // MARK: wireContext

    func test_wireContext_noSummary_sendsFullPathAndBareSystem() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        convo.systemPrompt = "Be nice."
        ctx.insert(convo)
        convo.appendToPath(msg(.user, "hi", 1))
        convo.appendToPath(msg(.assistant, "hello", 2))
        try ctx.save()

        let wire = convo.wireContext()
        XCTAssertEqual(wire.system, "Be nice.")
        XCTAssertEqual(wire.messages.map(\.content), ["hi", "hello"])
    }

    func test_wireContext_withSummary_foldsSummaryAndDropsSummarizedPrefix() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let m1 = msg(.user, "old-1", 1)
        let m2 = msg(.assistant, "old-2", 2)
        let m3 = msg(.user, "recent", 3)
        [m1, m2, m3].forEach(convo.appendToPath)
        try ctx.save()

        convo.summary = "They greeted each other."
        convo.summaryThrough = m2          // everything through m2 is summarized
        try ctx.save()

        let wire = convo.wireContext()
        XCTAssertTrue(wire.system.contains("They greeted each other."))
        XCTAssertEqual(wire.messages.map(\.content), ["recent"])   // only post-cutoff
    }

    // MARK: compactIfNeeded (via ChatSession + FakeProvider)

    func test_send_withAutoCompact_summarizesOldTurnsWhenOverThreshold() async throws {
        let ctx = try makeContext()
        // First call answers the summarization request, second is the actual reply.
        let provider = FakeProvider(scripts: [
            [.delta("SUMMARY: greetings exchanged."), .usage(promptTokens: 5, completionTokens: 3)],
            [.delta("ok"), .usage(promptTokens: 5, completionTokens: 1)],
        ])
        let session = ChatSession(client: provider, context: ctx,
                                  recorder: UsageRecorder(context: ctx))
        let server = Server(label: "S", host: "s"); ctx.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id)
        convo.autoCompact = true
        convo.compactKeepRecent = 1          // keep only the newest turn verbatim
        convo.compactThresholdPct = 0.0      // force compaction on any content
        ctx.insert(convo)
        // Seed some history so there's a prefix to summarize.
        for i in 0..<4 { convo.appendToPath(msg(i.isMultiple(of: 2) ? .user : .assistant, "turn \(i)", TimeInterval(i))) }
        try ctx.save()

        await session.send("new question", in: convo, server: server, contextWindow: 8192)

        XCTAssertEqual(convo.summary, "SUMMARY: greetings exchanged.")
        XCTAssertNotNil(convo.summaryThrough)
        // The actual reply still landed on the conversation.
        XCTAssertTrue(convo.messages.contains { $0.role == .assistant && $0.content == "ok" })
    }

    func test_send_withoutAutoCompact_neverSummarizes() async throws {
        let ctx = try makeContext()
        let provider = FakeProvider(events: [.delta("hi"), .usage(promptTokens: 1, completionTokens: 1)])
        let session = ChatSession(client: provider, context: ctx,
                                  recorder: UsageRecorder(context: ctx))
        let server = Server(label: "S", host: "s"); ctx.insert(server)
        let convo = Conversation(modelID: "m", serverID: server.id)   // autoCompact defaults off
        ctx.insert(convo)

        await session.send("hello", in: convo, server: server, contextWindow: 8192)

        XCTAssertNil(convo.summary)
    }
}
