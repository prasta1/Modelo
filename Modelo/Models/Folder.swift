import Foundation
import SwiftData

/// A user-created bucket for organizing conversations in the sidebar. Folders are
/// a manual, persistent layer above the automatic date grouping: a conversation is
/// either filed in exactly one folder or left unfiled (then date-bucketed).
@Model
final class Folder {
    /// Stable identity for view keys and the collapsed-section persistence key.
    /// Always minted in `init` — see the comment there for why the schema default
    /// can't be relied on.
    var id: UUID = UUID()
    var name: String = ""
    /// Manual order in the sidebar; lower sorts first.
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// Conversations filed in this folder. `.nullify` so deleting a folder un-files
    /// its conversations (clears their `folder`) rather than deleting them.
    @Relationship(deleteRule: .nullify, inverse: \Conversation.folder)
    var conversations: [Conversation] = []

    init(name: String, sortOrder: Int) {
        // SwiftData bakes a stored property's default value into the schema as a
        // single constant, so every instance that skips assigning `id`/`createdAt`
        // in init shares the SAME value (see the matching note in Conversation).
        // Assign explicitly to keep both unique per folder.
        self.id = UUID()
        self.createdAt = Date()
        self.name = name
        self.sortOrder = sortOrder
    }
}
