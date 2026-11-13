import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class ConversationTests: XCTestCase {
    /// Two freshly-created conversations must have distinct `id`s. This guards
    /// against the SwiftData default-value footgun, where relying on
    /// `var id: UUID = UUID()` makes every instance share one constant UUID and
    /// collapses sidebar rows into a single repeated entry.
    func test_init_assignsUniqueIDs() {
        let a = Conversation(modelID: "qwen3", serverID: nil)
        let b = Conversation(modelID: "qwen3", serverID: nil)
        XCTAssertNotEqual(a.id, b.id)
    }

    /// The sidebar and detail view key on `persistentModelID`, so that — not the
    /// app-level `id` — is the identity that must be unique. Insert two rows into a
    /// real (in-memory) context and confirm they're independently persisted with
    /// distinct persistent identifiers.
    func test_persistentModelIDs_areUniqueWhenStored() throws {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))

        let a = Conversation(modelID: "qwen3", serverID: nil)
        let b = Conversation(modelID: "qwen3", serverID: nil)
        context.insert(a)
        context.insert(b)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(stored.count, 2)
        XCTAssertNotEqual(a.persistentModelID, b.persistentModelID)
    }

    /// Archive files into the folder named "Archive" (any case), creating it only
    /// when none exists — so a hand-made archive folder is reused, not duplicated.
    func test_archiveFolder_reusesExistingOrCreates() throws {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self, Folder.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))

        let created = Folder.archive(among: [], in: context)
        XCTAssertEqual(created.name, "Archive")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).count, 1)

        let work = Folder(name: "Work", sortOrder: 0)
        let existing = Folder(name: "archive", sortOrder: 1)
        XCTAssertTrue(Folder.archive(among: [work, existing], in: context) === existing)
        XCTAssertFalse(work.isArchive)
    }
}
