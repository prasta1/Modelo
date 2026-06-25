import Foundation
import SwiftData

/// Per-model context length override for a server. Lets users explicitly set the
/// context window when the API doesn't report it (e.g. llama-swap, /v1/models fallback).
@Model
final class ModelContextOverride {
    var id: UUID = UUID()
    var modelID: String
    var contextLength: Int
    var serverID: UUID  // foreign key to Server
    /// Back-reference to the owning server.
    @Relationship var server: Server?
    
    init(modelID: String, contextLength: Int, serverID: UUID) {
        self.modelID = modelID
        self.contextLength = contextLength
        self.serverID = serverID
    }
}
