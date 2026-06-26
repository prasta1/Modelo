import Foundation
import SwiftData

/// One-time backfill for the conversation branching tree (§1.2).
///
/// Conversations created before branching store their messages as a flat,
/// `createdAt`-ordered list with no `parent` links. This links each one into a
/// single linear branch (m[n].parent = m[n-1]) and points the conversation's
/// active leaf at the last message, so `Conversation.activePath()` has a tree to
/// walk. New conversations are already linked by `ChatSession`, so they're skipped.
///
/// Idempotent: skips any conversation that already has tree links, and short-circuits
/// entirely after the first successful run via a `UserDefaults` flag.
enum BranchingMigration {
    static let flagKey = "didMigrateBranchingV1"

    /// Runs the backfill against `context` unless it has already completed. Safe to
    /// call on every launch.
    static func runIfNeeded(in context: ModelContext,
                            defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        // Only mark the migration done once the backfill has actually run *and* persisted.
        // A failed fetch or save must leave the flag unset so it retries on the next launch;
        // otherwise the backfill would be skipped forever (conversations would still work
        // via activePath's createdAt fallback, but never gain real tree links).
        do {
            try backfill(in: context)
            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so the backfill retries on the next launch.
        }
    }

    /// The actual chaining pass, factored out so tests can exercise it directly
    /// without touching `UserDefaults`.
    static func backfill(in context: ModelContext) throws {
        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        for convo in conversations {
            // Already linked (a re-run, or a conversation born after branching).
            if convo.messages.contains(where: { $0.parent != nil }) { continue }
            let ordered = convo.messages.sorted { $0.createdAt < $1.createdAt }
            var previous: Message?
            for msg in ordered {
                msg.parent = previous
                msg.branchIndex = 0
                previous = msg
            }
            convo.activeLeaf = ordered.last
        }
    }
}
