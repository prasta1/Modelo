import Foundation

/// Cheap token-count estimation for the live composer count and context gauge (§1.6).
///
/// v1 is a deliberate heuristic — roughly four characters per token — which is
/// accurate enough to drive a usage bar and a "you're approaching the window"
/// signal without bundling a tokenizer. A real BPE tokenizer (e.g. via
/// `swift-transformers`) is a future upgrade; see MERGE_PLAN §1.6 v2. Image
/// attachments aren't counted (their cost isn't derivable from text).
enum TokenEstimator {
    /// Approximate token count for a single string: ~4 chars/token, rounded up
    /// (0 for empty).
    static func estimate(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Approximate token count across a sequence of messages (sum of bodies).
    static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1.content) }
    }
}
