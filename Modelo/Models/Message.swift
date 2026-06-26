import Foundation
import SwiftData

/// Role stored as a raw String to keep the SwiftData schema simple.
enum MessageRole: String, Codable {
    case user, assistant, system, tool
}

/// A file attached to a user message (typically an image for vision models).
/// Stored as JSON in `Message.attachmentsJSON` for SwiftData compatibility.
struct MessageAttachment: Codable, Sendable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    init(data: Data, mimeType: String, fileName: String) {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// Base64 data URL for OpenAI-compatible vision APIs.
    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

extension MessageAttachment {
    static func decodeList(_ json: String) -> [MessageAttachment]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([MessageAttachment].self, from: data)
    }
}

extension Array where Element == MessageAttachment {
    /// JSON for persistence in `Message.attachmentsJSON`.
    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@Model
final class Message {
    var roleRaw: String = "assistant"
    var content: String = ""
    var createdAt: Date = Date()
    /// Completion token count, set after streaming finishes (assistant only).
    var tokenCount: Int?
    /// End-to-end throughput for this turn (completion tokens ÷ total turn time,
    /// so it includes prompt processing + TTFT — not decode-only speed). Assistant only.
    var tokensPerSecond: Double?
    /// On an assistant message that requested tools: JSON array of the calls
    /// (`[ToolCall]`), so the turn re-sends correctly and renders as cards.
    var toolCallsJSON: String?
    /// On a `.tool` result message: the id of the call it answers.
    var toolCallID: String?
    /// On a `.tool` result message: the tool's name (for the card label).
    var toolName: String?
    /// On a `.user` message: JSON-encoded `[MessageAttachment]` for image attachments.
    var attachmentsJSON: String?

    // MARK: Branching tree (§1.2)
    //
    // Messages form a tree rather than a flat list: regenerating or editing a turn
    // forks a sibling branch under the same parent. The conversation tracks which
    // leaf (and therefore which root→leaf path) is currently selected. Legacy flat
    // conversations are chained into a single linear branch by `BranchingMigration`.

    /// Parent turn in the conversation tree; nil for a root message. `.nullify` so
    /// deleting a parent doesn't fault its (separately owned) children.
    @Relationship(deleteRule: .nullify) var parent: Message?
    /// Child turns. Deleting a message removes its whole subtree.
    @Relationship(deleteRule: .cascade, inverse: \Message.parent) var children: [Message] = []
    /// Position among siblings sharing the same parent (0-based, in creation order).
    var branchIndex: Int = 0

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .assistant }
        set { roleRaw = newValue.rawValue }
    }

    init(role: MessageRole, content: String) {
        self.roleRaw = role.rawValue
        self.content = content
    }
}

extension Message {
    /// Messages sharing this one's parent (including self), ordered by branch index.
    /// Root messages (no parent) report only themselves — v1 doesn't branch roots.
    var siblings: [Message] {
        guard let parent else { return [self] }
        return parent.children.sorted { $0.branchIndex < $1.branchIndex }
    }

    /// This message's position among its siblings (0-based).
    var siblingIndex: Int {
        siblings.firstIndex { $0 === self } ?? 0
    }

    /// Descends to the tail of this message's subtree, following the most recent
    /// branch (highest `branchIndex`) at each step — the leaf to make active when
    /// the user navigates onto this branch.
    var subtreeLeaf: Message {
        var node = self
        while let next = node.children.max(by: { $0.branchIndex < $1.branchIndex }) {
            node = next
        }
        return node
    }
}
