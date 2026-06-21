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

    /// JSON-encoded `PersistentIdentifier` of the active leaf — the tail of the
    /// currently-selected root→leaf path through the branching tree (§1.2). Stored
    /// as `Data` (reusing the route-persistence idiom in `ContentView`) rather than
    /// adding an unstable UUID to `Message`. nil falls back to the latest message.
    var activeLeafData: Data?

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

    // MARK: Branching path (§1.2)

    /// The active leaf message, resolved from `activeLeafData`. Setting it re-encodes
    /// the message's `persistentModelID`; clearing it (nil) drops back to date order.
    var activeLeaf: Message? {
        get {
            guard let activeLeafData,
                  let pid = try? JSONDecoder().decode(PersistentIdentifier.self, from: activeLeafData)
            else { return nil }
            return messages.first { $0.persistentModelID == pid }
        }
        set {
            activeLeafData = newValue.flatMap { try? JSONEncoder().encode($0.persistentModelID) }
        }
    }

    /// The currently-selected path, root→leaf. Falls back to `createdAt` order for
    /// conversations that predate branching (no tree links yet).
    func activePath() -> [Message] {
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        let hasTree = messages.contains { $0.parent != nil }
        guard hasTree, let leaf = activeLeaf ?? ordered.last else { return ordered }
        var chain: [Message] = []
        var node: Message? = leaf
        while let n = node {
            chain.append(n)
            node = n.parent
        }
        return chain.reversed()
    }

    /// Links `message` after the current active leaf and advances the leaf to it —
    /// the normal linear append used while sending.
    func appendToPath(_ message: Message) {
        let leaf = activePath().last
        message.branchIndex = leaf?.children.count ?? messages.filter { $0.parent == nil }.count
        message.parent = leaf
        messages.append(message)
        activeLeaf = message
    }

    /// Creates `message` as a new sibling of `existing` (same parent) and makes it
    /// the active leaf — the branch forked when a user turn is edited & resent.
    func branch(_ message: Message, asSiblingOf existing: Message) {
        message.branchIndex = existing.siblings.count
        message.parent = existing.parent
        messages.append(message)
        activeLeaf = message
    }

    /// Removes a leaf `message` (e.g. an empty assistant bubble after a cancel) and
    /// moves the active leaf back to its parent.
    func dropLeaf(_ message: Message) {
        let parent = message.parent
        messages.removeAll { $0 === message }
        activeLeaf = parent
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
