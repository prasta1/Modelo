import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class ServerRegistryTests: XCTestCase {
    /// Builds an in-memory container so tests never touch disk.
    func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func test_serverBaseURL_composesHostAndPort() {
        let server = Server(label: "Studio", host: "studio", port: 1234)
        XCTAssertEqual(server.baseURL, "http://studio:1234")
    }

    func test_conversationDisplayTitle_fallsBackToNewChat() {
        // Untitled chats read "New Chat" (not the raw model id) until ChatSession
        // names them from a model run on the first exchange.
        let convo = Conversation(modelID: "qwen3-30b", serverID: nil)
        XCTAssertEqual(convo.displayTitle, "New Chat")
        convo.title = "CNC helper"
        XCTAssertEqual(convo.displayTitle, "CNC helper")
    }

    func test_seedIfNeeded_insertsLMStudioAndOpenRouterWhenEmpty() throws {
        let context = try makeContext()
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: context)
        let servers = try context.fetch(FetchDescriptor<Server>())
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers.filter { $0.kind == .lmStudio }.count, 1)
        XCTAssertEqual(servers.filter { $0.kind == .openRouter }.count, 1)
        XCTAssertEqual(Set(servers.map(\.label)), ["Mac Studio", "OpenRouter"])
    }

    func test_seedIfNeeded_isIdempotent() throws {
        let context = try makeContext()
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: context)
        registry.seedIfNeeded(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Server>()).count, 2)
    }

    func test_status_defaultsToUnknownThenReflectsSet() {
        let registry = ServerRegistry()
        let server = Server(label: "Studio", host: "studio")
        XCTAssertEqual(registry.status(for: server), .unknown)
        registry.setStatus(.online, for: server)
        XCTAssertEqual(registry.status(for: server), .online)
        XCTAssertTrue(registry.isOnline(server))
    }
}
