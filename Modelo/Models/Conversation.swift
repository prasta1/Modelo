import Foundation
import SwiftData

@Model
final class Conversation {
    /// ⚠️ NOT guaranteed unique for historical rows. Conversations created before
    /// the init below started minting a fresh UUID share one schema-default value
    /// (see `init`). Use `persistentModelID` for identity / view keys / lookups —
    /// never this. Kept only to avoid a store migration.
    var id: UUID = UUID()
    /// Model this conversation talks to (LM Studio model id).
    var modelID: String = ""
    /// Server this conversation is bound to (matches `Server.id`).
    var serverID: UUID?
    var title: String?
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade) var messages: [Message] = []

    /// Per-conversation system prompt override; nil = none.
    var systemPrompt: String?
    /// Per-conversation temperature override; nil = use default (0.7).
    var temperature: Double?
    /// Most recent total context tokens (prompt+completion) for the context bar.
    var contextTokensUsed: Int?
    /// Per-conversation toggle for agentic tool use. Default on; only has effect
    /// when the bound model advertises tool support.
    var toolsEnabled: Bool = true

    /// Folder this conversation is filed in; nil = unfiled (date-bucketed). Inverse
    /// of `Folder.conversations`.
    var folder: Folder?
    /// Pinned conversations surface in a "Pinned" section above folders and date
    /// buckets, and are excluded from their normal spot to avoid duplication.
    var isPinned: Bool = false

    /// Sidebar label. Once the first turn finishes, `ChatSession` fills `title` in
    /// from a model run; until then it reads "New Chat" rather than a raw model id.
    var displayTitle: String {
        title?.isEmpty == false ? title! : "New Chat"
    }

    init(modelID: String, serverID: UUID?) {
        // Assign a fresh UUID explicitly. SwiftData bakes a stored property's
        // default value (`var id: UUID = UUID()`) into the schema as a single
        // constant, so every instance that doesn't set `id` in init ends up
        // sharing the SAME UUID. Because `id` also satisfies Identifiable, that
        // collision collapses sidebar rows. Do NOT remove this line.
        self.id = UUID()
        // Same issue as `id`: the `= Date()` default is baked into the schema as
        // a constant (the compile-time date), so every row that skips this
        // assignment gets an identical timestamp, breaking sidebar sort order.
        self.createdAt = Date()
        self.modelID = modelID
        self.serverID = serverID
    }
}
