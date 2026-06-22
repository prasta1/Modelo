import Foundation

/// Renders a conversation's active path to a Markdown transcript (§3.2) and writes
/// it to ~/Downloads. Reasoning (`<think>…</think>`) is stripped from assistant turns
/// by default so the export reads cleanly.
enum ConversationExporter {
    static func markdown(for conversation: Conversation) -> String {
        var out = "# \(conversation.displayTitle)\n\n"
        for message in conversation.activePath() {
            switch message.role {
            case .user:
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out += "## User\n\n\(text)\n\n" }
            case .assistant:
                var text = ChatSession.stripReasoning(message.content)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out += "## Assistant\n\n\(text)\n\n" }
            case .tool, .system:
                continue   // omit tool plumbing from the readable transcript
            }
        }
        return out
    }

    /// Writes the transcript to ~/Downloads/<slug>-<stamp>.md. `stamp` is supplied so
    /// the function stays pure/testable; the caller passes the current time.
    @discardableResult
    static func writeToDownloads(_ conversation: Conversation, stamp: Date = Date()) -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appending(path: "\(slug(conversation.displayTitle))-\(f.string(from: stamp)).md")
        do {
            try markdown(for: conversation).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    /// Filesystem-safe slug from a title.
    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let s = String(cleaned).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "conversation" : String(s.prefix(60))
    }
}
