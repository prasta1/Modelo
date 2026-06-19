import Foundation

/// Pure helpers for per-turn usage metrics so the arithmetic is testable
/// independent of the live timing in `ChatSession`.
enum UsageMath {
    /// Decode speed. Returns 0 when elapsed is non-positive (avoids div-by-zero).
    static func tokensPerSecond(completionTokens: Int, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return Double(completionTokens) / elapsed
    }

    /// Seconds -> rounded milliseconds (for TTFT).
    static func millis(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}
