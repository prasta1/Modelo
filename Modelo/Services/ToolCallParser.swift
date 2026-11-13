import Foundation

/// Recovers tool calls that a model emitted as **text** instead of native OpenAI
/// `tool_calls`. Many local/quantized models (Qwen, Hermes, Llama variants) print the
/// call as `<tool_call>{…}</tool_call>`, a fenced ```json block, a lone JSON object, or
/// Qwen3-Coder's `<function=…><parameter=…>` XML,
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
        // 3. Qwen3-Coder XML: <function=name><parameter=key>value</parameter>…</function>,
        //    usually inside <tool_call> (whose body then isn't JSON, so step 1 skipped it).
        for groups in matchGroups(in: text, pattern: #"<function=([^>\s]+)>(.*?)</function>"#) {
            calls.append(xmlToolCall(name: groups[0], body: groups[1]))
        }
        // 4. The whole message is a single JSON call object (no delimiters).
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
        cleaned = remove(#"<function=[^>\s]+>.*?</function>"#, from: cleaned)
        return (calls, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True if `text` carries tool-call markup. When `extract` recovers nothing from
    /// such text, the model tried to call a tool and nothing ran.
    static func looksLikeAttempt(_ text: String) -> Bool {
        text.contains("<tool_call>") || text.contains("<function=")
    }

    /// Builds a call from the XML format's `<parameter=key>value</parameter>` pairs.
    /// ponytail: values stay strings (no tool schema here to coerce by); a numeric MCP
    /// argument would need the server's schema to convert.
    private static func xmlToolCall(name: String, body: String) -> ToolCall {
        var args: [String: String] = [:]
        for groups in matchGroups(in: body, pattern: #"<parameter=([^>\s]+)>(.*?)</parameter>"#) {
            // The format puts each value on its own lines; drop that one wrapping newline.
            var value = Substring(groups[1])
            if value.hasPrefix("\n") { value = value.dropFirst() }
            if value.hasSuffix("\n") { value = value.dropLast() }
            args[groups[0]] = String(value)
        }
        let json = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCall(id: "parsed-" + UUID().uuidString, name: name, arguments: json)
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
        matchGroups(in: text, pattern: pattern).compactMap(\.first)
    }

    /// Every match's capture groups, in order (group 0, the whole match, left out).
    private static func matchGroups(in text: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map {
                let r = m.range(at: $0)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func remove(_ pattern: String, from text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
