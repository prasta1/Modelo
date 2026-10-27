import Foundation

/// A one-click cloud endpoint in the Add Endpoint menu: a display name plus the
/// provider's OpenAI-compatible base URL. Shared so the Mac and iOS menus match.
struct CloudPreset: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let baseURL: String

    static let all: [CloudPreset] = [
        .init(name: "OpenAI",     baseURL: "https://api.openai.com/v1"),
        .init(name: "Groq",       baseURL: "https://api.groq.com/openai/v1"),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        .init(name: "Together",   baseURL: "https://api.together.xyz/v1"),
        .init(name: "DeepSeek",   baseURL: "https://api.deepseek.com/v1"),
        .init(name: "Mistral",    baseURL: "https://api.mistral.ai/v1"),
    ]
}
