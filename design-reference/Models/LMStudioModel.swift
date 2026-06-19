import Foundation

/// How a model presents in the picker / browser (handoff §8).
enum ModelState: Hashable {
    case selected   // amber checkmark, amber-tinted row, amber name
    case loaded     // green dot
    case idle       // hollow ring + amber "Load" button
    case cloud      // cloud glyph (OpenRouter)
}

/// A model the user can select or load. Grouped by `serverID` in the picker.
struct ModelInfo: Identifiable, Hashable {
    let id = UUID()
    var name: String            // "qwen3-coder"
    var meta: String            // "30B · MLX · 4bit"
    var contextLabel: String    // "262K"
    var state: ModelState
    var serverID: Server.ID
}

/// A row in the Model Browser grid (frame 01). Capabilities render as badges.
struct CatalogModel: Identifiable, Hashable {
    let id = UUID()
    var name: String            // "qwen3-coder"
    var specs: String           // "30B   ·   4bit   ·   262K ctx"
    var capabilities: [String]  // ["REASON", "VISION", ...]
    var isLoaded: Bool
}
