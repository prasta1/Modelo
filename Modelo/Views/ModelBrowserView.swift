import SwiftUI

/// Searchable browser for a cloud endpoint's model catalog. Filters default to Free-only
/// (the cost guardrail); Tools/Vision narrow further. Provider pills let users quickly
/// focus on a single model family. Selecting a row binds the conversation to that model
/// and dismisses.
struct ModelBrowserView: View {
    /// Cloud models discovered for the active endpoint.
    let models: [DiscoveredModel]
    @Binding var selection: DiscoveredModel?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var freeOnly = true     // Free-by-default per spec
    @State private var toolsOnly = false
    @State private var visionOnly = false
    @State private var selectedProvider: String? = nil

    /// Unique provider IDs sorted by model count (most models first).
    private var providers: [String] {
        var counts: [String: Int] = [:]
        for item in models {
            if let p = item.model.providerID { counts[p, default: 0] += 1 }
        }
        return counts.keys.sorted { counts[$0]! > counts[$1]! }
    }

    private var filtered: [DiscoveredModel] {
        models.filter { item in
            let m = item.model
            if freeOnly && !m.isFree { return false }
            if toolsOnly && !m.supportsToolUse { return false }
            if visionOnly && !m.supportsVision { return false }
            if let p = selectedProvider, m.providerID != p { return false }
            if !query.isEmpty && !m.id.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cloud models").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .help("Close")
            }
            .padding(12)
            HStack(spacing: 12) {
                Toggle("Free", isOn: $freeOnly)
                    .help("Show only free models")
                Toggle("Tools", isOn: $toolsOnly)
                    .help("Show only tool-capable models")
                Toggle("Vision", isOn: $visionOnly)
                    .help("Show only vision-capable models")
                Spacer()
                Text("\(filtered.count) of \(models.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.button).padding(.horizontal, 12).padding(.bottom, 8)
            if !providers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterPill(label: "All", isActive: selectedProvider == nil) {
                            selectedProvider = nil
                        }
                        ForEach(providers, id: \.self) { provider in
                            FilterPill(
                                label: providerDisplayName(provider),
                                isActive: selectedProvider == provider
                            ) {
                                selectedProvider = selectedProvider == provider ? nil : provider
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 8)
            }
            Divider()
            List(filtered, selection: Binding(
                get: { selection },
                set: { selection = $0; if $0 != nil { dismiss() } }
            )) { item in
                HStack {
                    Text(item.model.shortName)
                    CapabilityChips(model: item.model)
                    Spacer()
                }
                .tag(item)
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search models")
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func providerDisplayName(_ id: String) -> String {
        let known: [String: String] = [
            "anthropic":  "Anthropic",
            "openai":     "OpenAI",
            "google":     "Google",
            "meta-llama": "Meta",
            "mistralai":  "Mistral",
            "cohere":     "Cohere",
            "qwen":       "Qwen",
            "deepseek":   "DeepSeek",
            "x-ai":       "xAI",
            "amazon":     "Amazon",
            "microsoft":  "Microsoft",
            "nvidia":     "NVIDIA",
            "perplexity": "Perplexity",
            "01-ai":      "01.AI",
            "databricks": "Databricks",
        ]
        return known[id] ?? id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}


