import Foundation
import SwiftData

/// Inserts one `UsageRecord` per completed turn. Failures are swallowed —
/// usage logging must never break chatting.
@MainActor
struct UsageRecorder {
    let context: ModelContext

    func record(modelID: String, serverLabel: String, promptTokens: Int,
                completionTokens: Int, tokensPerSecond: Double, ttftMillis: Int) {
        context.insert(UsageRecord(
            modelID: modelID, serverLabel: serverLabel,
            promptTokens: promptTokens, completionTokens: completionTokens,
            tokensPerSecond: tokensPerSecond, ttftMillis: ttftMillis
        ))
        try? context.save()
    }
}
