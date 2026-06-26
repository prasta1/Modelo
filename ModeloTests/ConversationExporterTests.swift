import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class ConversationExporterTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self,
                             UsageRecord.self, Persona.self, Folder.self, Preset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func msg(_ role: MessageRole, _ content: String, _ t: TimeInterval) -> Message {
        let m = Message(role: role, content: content); m.createdAt = Date(timeIntervalSince1970: t); return m
    }

    func test_markdown_rendersUserAndAssistantTurns() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil); convo.title = "My Chat"
        ctx.insert(convo)
        convo.appendToPath(msg(.user, "hello", 1))
        convo.appendToPath(msg(.assistant, "<think>hmm</think>hi there", 2))
        convo.appendToPath(msg(.tool, "tool noise", 3))   // omitted
        try ctx.save()

        let md = ConversationExporter.markdown(for: convo)
        XCTAssertTrue(md.hasPrefix("# My Chat"))
        XCTAssertTrue(md.contains("## User\n\nhello"))
        XCTAssertTrue(md.contains("## Assistant\n\nhi there"))   // reasoning stripped
        XCTAssertFalse(md.contains("tool noise"))
        XCTAssertFalse(md.contains("<think>"))
    }

    func test_slug_isFilesystemSafe() {
        XCTAssertEqual(ConversationExporter.slug("Hello, World!  Foo"), "hello-world-foo")
        XCTAssertEqual(ConversationExporter.slug(""), "conversation")
        XCTAssertEqual(ConversationExporter.slug("///"), "conversation")
    }
}
