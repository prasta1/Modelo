import Foundation

enum Role: Hashable {
    case user
    case assistant
}

/// An inline tool-call chip in an assistant turn ("Searched the web · 3 sources").
struct ToolCall: Hashable {
    var title: String           // "Searched the web"
    var detail: String          // "\u{201C}taco history\u{201D} · 3 sources"
    var systemImage: String = "globe"
}

/// Per-message footer metrics (mono).
struct MessageMetrics: Hashable {
    var ttft: String            // "TTFT 240ms"
    var rate: String            // "42 tok/s"
    var tokens: String          // "312 tokens"
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    var role: Role
    var text: String
    var modelName: String = ""          // assistant header
    var timestamp: String = ""          // "21:24"
    var toolCall: ToolCall? = nil
    var metrics: MessageMetrics? = nil
    var isStreaming: Bool = false       // drives the "streaming" badge + caret
}
