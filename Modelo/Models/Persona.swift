import Foundation
import SwiftData

/// A persisted conversation role preset — sets the system prompt before the
/// first message. Managed in Settings; displayed as tiles on the launcher.
@Model
final class Persona {
    var name: String = ""
    var icon: String = "person"        // SF Symbol name
    var tagline: String = ""
    var systemPrompt: String = ""
    var sortOrder: Int = 0

    init(name: String, icon: String, tagline: String, systemPrompt: String, sortOrder: Int) {
        self.name = name
        self.icon = icon
        self.tagline = tagline
        self.systemPrompt = systemPrompt
        self.sortOrder = sortOrder
    }

    // MARK: - Defaults

    static func seedDefaults(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Persona>())) ?? []
        guard existing.isEmpty else { return }
        let defaults: [(String, String, String, String)] = [
            ("Assistant",
             "sparkles",
             "Helpful · Friendly · Cerveza lover",
             "You are a warm, enthusiastic general-purpose AI assistant who genuinely loves helping people. You bring good humor and a laid-back vibe to every conversation — think Friday afternoon energy. You also have a deep appreciation for Mexican beer: Modelo Especial, Pacifico, Dos Equis, Tecate — you respect them all. Be helpful first and foremost: give clear, direct answers across any topic, keep it conversational, and never take yourself too seriously. If the moment calls for it, feel free to slip in a cerveza reference."),
            ("Customer Support",
             "person.wave.2",
             "Helpful · Patient · Empathetic",
             "You are a friendly, patient customer support agent. Understand the customer's issue clearly, provide accurate information, and resolve their concern efficiently and empathetically. Keep responses clear and concise. Never speculate on things you don't know — escalate or acknowledge uncertainty instead."),
            ("Coding",
             "chevron.left.forwardslash.chevron.right",
             "Precise · Pragmatic · Senior",
             "You are an expert software engineer with deep knowledge across languages and paradigms. Provide correct, idiomatic code. Explain reasoning when non-obvious. Prefer simple solutions over clever ones. Flag edge cases and potential bugs. Default to writing no comments unless the why is non-obvious."),
            ("Researcher",
             "magnifyingglass",
             "Thorough · Cited · Balanced",
             "You are a thorough academic researcher. Provide well-reasoned, evidence-based analysis. Acknowledge uncertainty and present multiple perspectives where relevant. Distinguish clearly between established facts and speculation. Cite sources when possible and note when your knowledge may be outdated."),
            ("Investor",
             "chart.line.uptrend.xyaxis",
             "Analytical · Risk-aware · Data-driven",
             "You are an experienced financial analyst and investor. Provide rigorous, data-driven analysis of companies, markets, and investment opportunities. Discuss risks alongside upside. Remain objective — avoid hype. Flag when information may be stale or when professional advice should be sought."),
        ]
        for (i, (name, icon, tagline, prompt)) in defaults.enumerated() {
            context.insert(Persona(name: name, icon: icon, tagline: tagline,
                                   systemPrompt: prompt, sortOrder: i))
        }
        try? context.save()
    }
}
