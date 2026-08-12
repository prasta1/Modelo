import SwiftUI

/// Band 2: ALL / FREE / TOOLS / VISION / REASON / LOADED / FAVS chip row.
struct ModelFilterChipsView: View {
    let vm: ModelCatalogViewModel

    private struct ChipDef: Identifiable {
        let id: String
        let label: String
        let tint: Color
    }

    private let chips: [ChipDef] = [
        ChipDef(id: "all",    label: "All",    tint: Theme.amber),
        ChipDef(id: "free",   label: "Free",   tint: Theme.green),
        ChipDef(id: "tools",  label: "Tools",  tint: Theme.amber),
        ChipDef(id: "vision", label: "Vision", tint: Theme.blue),
        ChipDef(id: "reason", label: "Reason", tint: Theme.purple),
        ChipDef(id: "loaded", label: "Loaded", tint: Theme.green),
        ChipDef(id: "favs",   label: "Favs",   tint: Theme.amber),
    ]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips) { chip in
                chipButton(chip)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func chipButton(_ chip: ChipDef) -> some View {
        let isAll = chip.id == "all"
        let active = isAll ? vm.activeFilters.isEmpty : vm.activeFilters.contains(chip.id)

        Button {
            if isAll {
                vm.activeFilters.removeAll()
            } else if vm.activeFilters.contains(chip.id) {
                vm.activeFilters.remove(chip.id)
            } else {
                vm.activeFilters.insert(chip.id)
            }
        } label: {
            Text(chip.label.uppercased())
                .font(Theme.label(9))
                .tracking(0.8)
                .foregroundStyle(active ? chip.tint : Theme.textFaint)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    active ? chip.tint.opacity(0.09) : Color.clear,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        active ? chip.tint.opacity(0.35) : Theme.line,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
