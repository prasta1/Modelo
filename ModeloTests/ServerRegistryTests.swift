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

    func test_seedIfNeeded_insertsLocalServerWhenEmpty() throws {
        let context = try makeContext()
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: context)
        let servers = try context.fetch(FetchDescriptor<Server>())
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.kind, .lmStudio)
        XCTAssertEqual(servers.first?.label, "Local Server")
    }

    func test_seedIfNeeded_isIdempotent() throws {
        let context = try makeContext()
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: context)
        registry.seedIfNeeded(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Server>()).count, 1)
    }

    func test_status_defaultsToUnknownThenReflectsSet() {
        let registry = ServerRegistry()
        let server = Server(label: "Studio", host: "studio")
        XCTAssertEqual(registry.status(for: server), .unknown)
        registry.setStatus(.online, for: server)
        XCTAssertEqual(registry.status(for: server), .online)
        XCTAssertTrue(registry.isOnline(server))
    }

    // MARK: Apple Intelligence seeding

    private func appleRows(_ ctx: ModelContext) throws -> [Server] {
        try ctx.fetch(FetchDescriptor<Server>()).filter { $0.kind == .appleIntelligence }
    }

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    func test_seedAppleIntelligence_insertsOnceWhenEligible() throws {
        let ctx = try makeContext(), defaults = freshDefaults()
        let registry = ServerRegistry()
        registry.seedAppleIntelligenceIfNeeded(in: ctx, isEligible: true, defaults: defaults)
        registry.seedAppleIntelligenceIfNeeded(in: ctx, isEligible: true, defaults: defaults)
        XCTAssertEqual(try appleRows(ctx).count, 1)
        XCTAssertEqual(try appleRows(ctx).first?.label, "Apple Intelligence")
        XCTAssertTrue(defaults.bool(forKey: "didSeedAppleIntelligence"))
    }

    func test_seedAppleIntelligence_skipsWhenIneligible() throws {
        let ctx = try makeContext(), defaults = freshDefaults()
        ServerRegistry().seedAppleIntelligenceIfNeeded(in: ctx, isEligible: false, defaults: defaults)
        XCTAssertEqual(try appleRows(ctx).count, 0)
        XCTAssertFalse(defaults.bool(forKey: "didSeedAppleIntelligence"))
    }

    func test_seedAppleIntelligence_deletedRowStaysDeleted() throws {
        let ctx = try makeContext(), defaults = freshDefaults()
        let registry = ServerRegistry()
        registry.seedAppleIntelligenceIfNeeded(in: ctx, isEligible: true, defaults: defaults)
        try appleRows(ctx).forEach(ctx.delete)
        try ctx.save()
        registry.seedAppleIntelligenceIfNeeded(in: ctx, isEligible: true, defaults: defaults)
        XCTAssertEqual(try appleRows(ctx).count, 0)
    }

    func test_seedAppleIntelligence_sortsLast() throws {
        let ctx = try makeContext(), defaults = freshDefaults()
        ctx.insert(Server(label: "A", host: "a", sortOrder: 0))
        ctx.insert(Server(label: "B", host: "b", sortOrder: 3))
        try ctx.save()
        ServerRegistry().seedAppleIntelligenceIfNeeded(in: ctx, isEligible: true, defaults: defaults)
        XCTAssertGreaterThan(try appleRows(ctx).first?.sortOrder ?? -1, 3)
    }
}
