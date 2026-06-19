import SwiftUI

/// Searchable browser for OpenRouter's large catalog. Filters default to Free-only
/// (the cost guardrail); Tools/Vision narrow further. Selecting a row binds the
/// conversation to that model and dismisses.
struct ModelBrowserView: View {
    /// OpenRouter models discovered for the active endpoint.
    let models: [DiscoveredModel]
    @Binding var selection: DiscoveredModel?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var freeOnly = true     // Free-by-default per spec
    @State private var toolsOnly = false
    @State private var visionOnly = false

    private var filtered: [DiscoveredModel] {
        models.filter { item in
            let m = item.model
            if freeOnly && !m.isFree { return false }
            if toolsOnly && !m.supportsToolUse { return false }
            if visionOnly && !m.supportsVision { return false }
            if !query.isEmpty && !m.id.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OpenRouter models").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            HStack(spacing: 12) {
                Toggle("Free", isOn: $freeOnly)
                Toggle("Tools", isOn: $toolsOnly)
                Toggle("Vision", isOn: $visionOnly)
                Spacer()
                Text("\(filtered.count) of \(models.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.button).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            List(filtered, selection: Binding(
                get: { selection },
                set: { selection = $0; if $0 != nil { dismiss() } }
            )) { item in
                HStack {
                    Text(item.model.shortName)
                    if item.model.isFree { Chip(text: "free", tint: Theme.Palette.live) }
                    CapabilityChips(model: item.model)
                    Spacer()
                }
                .tag(item)
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search models")
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}
