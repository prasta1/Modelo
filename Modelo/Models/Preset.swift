import Foundation
import SwiftData

/// A reusable bundle of generation settings (§1.4b): a name, an optional system
/// prompt, and a set of `SamplingParams`. Applying a preset writes its system prompt
/// and sampling overrides onto a conversation.
@Model
final class Preset {
    var name: String = ""
    var systemPrompt: String?
    /// JSON-encoded `SamplingParams` (kept as a string so the schema stays a scalar).
    var samplingJSON: String?
    var sortOrder: Int = 0

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }

    /// The preset's sampling overrides, decoded from `samplingJSON`.
    var sampling: SamplingParams {
        get {
            samplingJSON.flatMap { try? JSONDecoder().decode(SamplingParams.self, from: Data($0.utf8)) }
                ?? SamplingParams()
        }
        set {
            samplingJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
