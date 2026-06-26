import Foundation
import SwiftData

/// Per-model context length override for a server. Lets users explicitly set the
/// context window when the API doesn't report it (e.g. llama-swap, /v1/models fallback).
@Model
final class ModelContextOverride {
    var id: UUID = UUID()
    var modelID: String
    var contextLength: Int
    /// Owning server — the single source of truth. Replaces the old denormalized
    /// `serverID` (which was only ever written, never read, so it could silently
    /// diverge from this relationship). Linked via `Server.contextLengthOverrides`.
    @Relationship var server: Server?

    init(modelID: String, contextLength: Int) {
        self.modelID = modelID
        self.contextLength = contextLength
    }
}
