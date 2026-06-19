import Foundation
import SwiftData

/// One record per completed assistant turn. Phase 1 only writes these; the
/// Phase 5 reporting subsystem reads and aggregates them.
@Model
final class UsageRecord {
    var timestamp: Date = Date()
    var modelID: String = ""
    /// Human label of the server that served the turn.
    var serverLabel: String = ""
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var tokensPerSecond: Double = 0
    /// Time-to-first-token in milliseconds.
    var ttftMillis: Int = 0

    init(modelID: String, serverLabel: String, promptTokens: Int,
         completionTokens: Int, tokensPerSecond: Double, ttftMillis: Int) {
        self.modelID = modelID
        self.serverLabel = serverLabel
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.ttftMillis = ttftMillis
    }
}
