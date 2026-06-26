import Foundation

/// Recovers tool calls that a model emitted as **text** instead of native OpenAI
/// `tool_calls`. Many local/quantized models (Qwen, Hermes, Llama variants) print the
/// call as `<tool_call>{…}</tool_call>`, a fenced ```json block, or a lone JSON object,
/// and the server's chat template fails to convert it — so without this, the call is
/// silently shown as the "answer" and never runs. Used as a fallback when the native
/// `tool_calls` list is empty.
enum ToolCallParser {
    /// Returns any recovered calls plus the text with their markup stripped (so the
    /// chat doesn't display the raw call). Empty calls ⇒ original text unchanged.
    static func extract(from text: String) -> (calls: [ToolCall], cleaned: String) {
        var calls: [ToolCall] = []

        // 1. <tool_call> … </tool_call>  (Qwen / Hermes / Nous)
        for body in captures(in: text, pattern: #"<tool_call>\s*(.*?)\s*</tool_call>"#) {
            if let c = toolCall(from: body) { calls.append(c) }
        }
        // 2. Fenced ```json / ```tool_call blocks that look like a call.
        for body in captures(in: text, pattern: #"```(?:json|tool_call|tool_code)?\s*\n?(.*?)```"#) {
            if looksLikeCall(body), let c = toolCall(from: body) { calls.append(c) }
        }
        // 3. The whole message is a single JSON call object (no delimiters).
        if calls.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), looksLikeCall(trimmed), let c = toolCall(from: trimmed) {
                return ([c], "")
            }
        }
        guard !calls.isEmpty else { return ([], text) }

        var cleaned = text
        cleaned = remove(#"<tool_call>\s*.*?\s*</tool_call>"#, from: cleaned)
        cleaned = remove(#"```(?:json|tool_call|tool_code)?\s*\n?.*?```"#, from: cleaned)
        return (calls, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A JSON blob is call-shaped if it names a tool and carries an argument bag.
    private static func looksLikeCall(_ s: String) -> Bool {
        s.contains("\"name\"") && (s.contains("\"arguments\"") || s.contains("\"parameters\""))
    }

    /// Decode a single `{name, arguments}` object (also unwraps `tool_call`/`function`).
    private static func toolCall(from json: String) -> ToolCall? {
        guard let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dict = (top["tool_call"] as? [String: Any]) ?? (top["function"] as? [String: Any]) ?? top
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let argsAny = dict["arguments"] ?? dict["parameters"] ?? [String: Any]()
        let argsString: String
        if let s = argsAny as? String {
            argsString = s
        } else if let d = try? JSONSerialization.data(withJSONObject: argsAny),
                  let s = String(data: d, encoding: .utf8) {
            argsString = s
        } else {
            argsString = "{}"
        }
        return ToolCall(id: "parsed-" + UUID().uuidString, name: name, arguments: argsString)
    }

    // MARK: Regex helpers (dot matches newlines so multi-line JSON is captured whole)

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    private static func remove(_ pattern: String, from text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
