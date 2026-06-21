import XCTest
import SwiftData
@testable import Modelo

/// Covers the §1.2 branching tree: active-path walking, linear append, sibling
/// branching + navigation, the launch-time backfill migration, and leaf removal.
@MainActor
final class ConversationBranchingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self,
                             UsageRecord.self, Persona.self, Folder.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    /// Distinct timestamps so `createdAt` ordering is unambiguous in assertions.
    private func msg(_ role: MessageRole, _ content: String, _ t: TimeInterval) -> Message {
        let m = Message(role: role, content: content)
        m.createdAt = Date(timeIntervalSince1970: t)
        return m
    }

    // MARK: Active path

    /// A legacy conversation (messages appended with no tree links) still yields a
    /// path — falling back to creation order.
    func test_activePath_fallsBackToDateOrder_whenUnlinked() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        convo.messages.append(msg(.user, "1", 1))
        convo.messages.append(msg(.assistant, "2", 2))
        try ctx.save()

        XCTAssertEqual(convo.activePath().map(\.content), ["1", "2"])
    }

    func test_appendToPath_buildsLinearChain() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let u = msg(.user, "u", 1)
        let a = msg(.assistant, "a", 2)
        convo.appendToPath(u)
        convo.appendToPath(a)
        try ctx.save()

        XCTAssertNil(u.parent)
        XCTAssertTrue(a.parent === u)
        XCTAssertEqual(convo.activePath().map(\.content), ["u", "a"])
    }

    // MARK: Branching + navigation

    /// Editing a (non-root) user turn forks a sibling under the same parent and
    /// switches the active path onto it.
    func test_branch_forksSiblingAndActivatesIt() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let u1 = msg(.user, "u1", 1), a1 = msg(.assistant, "a1", 2)
        let u2 = msg(.user, "u2", 3), a2 = msg(.assistant, "a2", 4)
        [u1, a1, u2, a2].forEach(convo.appendToPath)
        try ctx.save()
        XCTAssertEqual(convo.activePath().map(\.content), ["u1", "a1", "u2", "a2"])

        // Edit u2 -> new sibling u2b under a1.
        let u2b = msg(.user, "u2b", 5)
        convo.branch(u2b, asSiblingOf: u2)
        try ctx.save()

        XCTAssertTrue(u2b.parent === a1)
        XCTAssertEqual(u2.siblings.count, 2)
        XCTAssertEqual(u2.siblingIndex, 0)
        XCTAssertEqual(u2b.siblingIndex, 1)
        XCTAssertEqual(convo.activePath().map(\.content), ["u1", "a1", "u2b"])
    }

    /// Navigating back to the original branch re-selects its subtree leaf and
    /// restores that branch's full path (exercises permanent-id leaf resolution).
    func test_selectingSiblingSubtreeLeaf_restoresThatBranch() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let u1 = msg(.user, "u1", 1), a1 = msg(.assistant, "a1", 2)
        let u2 = msg(.user, "u2", 3), a2 = msg(.assistant, "a2", 4)
        [u1, a1, u2, a2].forEach(convo.appendToPath)
        let u2b = msg(.user, "u2b", 5)
        convo.branch(u2b, asSiblingOf: u2)
        try ctx.save()

        // u2's subtree leaf is a2; selecting it brings back the original branch.
        convo.activeLeaf = u2.subtreeLeaf
        try ctx.save()
        XCTAssertTrue(u2.subtreeLeaf === a2)
        XCTAssertEqual(convo.activePath().map(\.content), ["u1", "a1", "u2", "a2"])
    }

    func test_dropLeaf_removesMessageAndMovesActiveLeafToParent() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let u = msg(.user, "u", 1)
        let a = msg(.assistant, "", 2)   // empty assistant bubble, e.g. cancelled
        convo.appendToPath(u)
        convo.appendToPath(a)
        try ctx.save()

        convo.dropLeaf(a)
        try ctx.save()

        XCTAssertEqual(convo.messages.count, 1)
        XCTAssertTrue(convo.activeLeaf === u)
        XCTAssertEqual(convo.activePath().map(\.content), ["u"])
    }

    // MARK: Migration

    func test_backfill_chainsFlatConversation() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let m1 = msg(.user, "1", 1), m2 = msg(.assistant, "2", 2), m3 = msg(.user, "3", 3)
        [m1, m2, m3].forEach { convo.messages.append($0) }   // legacy: no links
        try ctx.save()

        BranchingMigration.backfill(in: ctx)
        try ctx.save()

        XCTAssertNil(m1.parent)
        XCTAssertTrue(m2.parent === m1)
        XCTAssertTrue(m3.parent === m2)
        XCTAssertTrue(convo.activeLeaf === m3)
        XCTAssertEqual(convo.activePath().map(\.content), ["1", "2", "3"])
    }

    /// Idempotent: a conversation already linked (via appendToPath) is left alone.
    func test_backfill_skipsAlreadyLinked() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        let u = msg(.user, "u", 1), a = msg(.assistant, "a", 2)
        convo.appendToPath(u)
        convo.appendToPath(a)
        try ctx.save()

        BranchingMigration.backfill(in: ctx)

        XCTAssertTrue(a.parent === u)   // unchanged
        XCTAssertNil(u.parent)
    }

    func test_runIfNeeded_setsFlagAndRunsOnce() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        ctx.insert(convo)
        convo.messages.append(msg(.user, "1", 1))
        convo.messages.append(msg(.assistant, "2", 2))
        try ctx.save()

        let suite = "branching-migration-test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertFalse(defaults.bool(forKey: BranchingMigration.flagKey))
        BranchingMigration.runIfNeeded(in: ctx, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: BranchingMigration.flagKey))
        XCTAssertEqual(convo.activePath().map(\.content), ["1", "2"])

        defaults.removePersistentDomain(forName: suite)
    }
}
