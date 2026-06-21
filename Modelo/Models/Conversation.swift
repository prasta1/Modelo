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
    /// Per-conversation sampling overrides (§1.4); nil = inherit the global default.
    /// `temperature` predates the rest (kept for store compatibility).
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var stopSequences: [String]?
    /// Most recent total context tokens (prompt+completion) for the context bar.
    var contextTokensUsed: Int?
    /// Per-conversation toggle for agentic tool use. Default on; only has effect
    /// when the bound model advertises tool support.
    var toolsEnabled: Bool = true

    /// Auto-compaction (§1.5): when on and the active path nears the model's context
    /// window, older turns are summarized into `summary` so the chat runs indefinitely.
    var autoCompact: Bool = false
    /// The compaction summary text (nil = none yet).
    var summary: String?
    /// Encoded `PersistentIdentifier` of the last message folded into `summary`;
    /// messages after it are sent verbatim. Same idiom as `activeLeafData`.
    var summaryThroughData: Data?
    /// Fraction of the context window at which to compact (nil = default 0.85).
    var compactThresholdPct: Double?
    /// Most recent messages kept verbatim, never summarized (nil = default 8).
    var compactKeepRecent: Int?

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

    /// This conversation's sampling overrides as a `SamplingParams` (§1.4) — nil
    /// fields inherit the global default when resolved via `overlaying(_:)`. Settable
    /// so the per-conversation editor and "apply preset" can write all fields at once.
    var samplingOverride: SamplingParams {
        get {
            SamplingParams(temperature: temperature, topP: topP, maxTokens: maxTokens,
                           frequencyPenalty: frequencyPenalty, presencePenalty: presencePenalty,
                           stop: stopSequences)
        }
        set {
            temperature = newValue.temperature
            topP = newValue.topP
            maxTokens = newValue.maxTokens
            frequencyPenalty = newValue.frequencyPenalty
            presencePenalty = newValue.presencePenalty
            stopSequences = newValue.stop
        }
    }

    /// Applies a preset (§1.4b): its sampling overrides replace this chat's, and a
    /// non-empty system prompt overwrites the chat's.
    func apply(_ preset: Preset) {
        if let prompt = preset.systemPrompt { systemPrompt = prompt }
        samplingOverride = preset.sampling
    }

    // MARK: Auto-compaction (§1.5)

    /// The last message folded into `summary`, resolved from `summaryThroughData`.
    var summaryThrough: Message? {
        get {
            guard let summaryThroughData,
                  let pid = try? JSONDecoder().decode(PersistentIdentifier.self, from: summaryThroughData)
            else { return nil }
            return messages.first { $0.persistentModelID == pid }
        }
        set { summaryThroughData = newValue.flatMap { try? JSONEncoder().encode($0.persistentModelID) } }
    }

    /// The context to send for the next request, applying any compaction summary:
    /// the system prompt (with the summary appended) and the messages to send — those
    /// after the summarized cutoff, or the whole active path when there's no summary.
    func wireContext() -> (system: String, messages: [Message]) {
        let path = activePath()
        let base = systemPrompt ?? ""
        guard let summary, !summary.isEmpty, let through = summaryThrough,
              let idx = path.firstIndex(where: { $0 === through }) else {
            return (base, path)
        }
        let recent = Array(path.suffix(from: path.index(after: idx)))
        let note = "Summary of the earlier conversation:\n\(summary)"
        return (base.isEmpty ? note : "\(base)\n\n\(note)", recent)
    }

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
    ///
    /// `ordered.last` fallback: a just-inserted leaf's temporary `persistentModelID`
    /// stops resolving after `save()`, so `activeLeaf` reads `nil` until re-encoded —
    /// harmless, since that leaf is also the newest by `createdAt`. Navigation (where
    /// the exact leaf matters) always sets `activeLeaf` from a saved, permanent-id row.
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

    /// Next branch index under `siblings` — one past the highest in use. Monotonic
    /// (rather than `count`) so indices never collide with a survivor after a sibling
    /// is dropped.
    private func nextBranchIndex(among siblings: [Message]) -> Int {
        (siblings.map(\.branchIndex).max() ?? -1) + 1
    }

    /// Links `message` after the current active leaf and advances the leaf to it —
    /// the normal linear append used while sending.
    func appendToPath(_ message: Message) {
        let leaf = activePath().last
        let siblings = leaf?.children ?? messages.filter { $0.parent == nil }
        message.branchIndex = nextBranchIndex(among: siblings)
        message.parent = leaf
        messages.append(message)
        activeLeaf = message
    }

    /// Creates `message` as a new sibling of `existing` (same parent) and makes it
    /// the active leaf — the branch forked when a user turn is edited & resent.
    func branch(_ message: Message, asSiblingOf existing: Message) {
        message.branchIndex = nextBranchIndex(among: existing.siblings)
        message.parent = existing.parent
        messages.append(message)
        activeLeaf = message
    }

    /// Removes a leaf `message` (e.g. an empty assistant bubble after a cancel) and
    /// moves the active leaf back to its parent. Detaches `message.parent` too, so the
    /// dropped node doesn't linger in `parent.children` as a phantom branch; the caller
    /// is responsible for deleting it from the context.
    func dropLeaf(_ message: Message) {
        let parent = message.parent
        message.parent = nil
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
