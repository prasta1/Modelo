import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class ChatSessionStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeSession(_ context: ModelContext) -> ChatSession {
        ChatSession(client: FakeProvider(events: []), context: context,
                    recorder: UsageRecorder(context: context))
    }

    func test_keepsASeparateSessionPerConversation() throws {
        let context = try makeContext()
        let a = Conversation(modelID: "m", serverID: nil); context.insert(a)
        let b = Conversation(modelID: "m", serverID: nil); context.insert(b)
        try context.save()   // stable persistentModelIDs to key on

        let store = ChatSessionStore()
        XCTAssertNil(store.session(for: a.persistentModelID))

        let sessionA = makeSession(context)
        store.setSession(sessionA, for: a.persistentModelID)

        XCTAssertTrue(store.session(for: a.persistentModelID) === sessionA)
        XCTAssertNil(store.session(for: b.persistentModelID),
                     "Each conversation has its own session slot.")
    }

    func test_discardClearsSession() throws {
        let context = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil); context.insert(convo)
        try context.save()

        let store = ChatSessionStore()
        store.setSession(makeSession(context), for: convo.persistentModelID)
        XCTAssertNotNil(store.session(for: convo.persistentModelID))

        store.discard(convo.persistentModelID)
        XCTAssertNil(store.session(for: convo.persistentModelID))
    }
}
