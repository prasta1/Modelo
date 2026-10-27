import SwiftUI

/// Band 2: ALL / FREE / TOOLS / VISION / REASON / LOADED / FAVS chip row.
struct ModelFilterChipsView: View {
    let vm: ModelCatalogViewModel

    private struct ChipDef: Identifiable {
        let id: String
        let label: String
        let tint: Color
        /// Same glyph `ModelTableRow` uses for this capability, so the chip row
        /// doubles as the table's icon legend. Keep the two in sync.
        var symbol: String? = nil
    }

    private let chips: [ChipDef] = [
        ChipDef(id: "all",    label: "All",    tint: Theme.amber),
        ChipDef(id: "free",   label: "Free",   tint: Theme.green,  symbol: "gift"),
        ChipDef(id: "tools",  label: "Tools",  tint: Theme.amber,  symbol: "wrench.and.screwdriver"),
        ChipDef(id: "vision", label: "Vision", tint: Theme.blue,   symbol: "eye"),
        ChipDef(id: "reason", label: "Reason", tint: Theme.purple, symbol: "brain"),
        ChipDef(id: "loaded", label: "Loaded", tint: Theme.green,  symbol: "memorychip"),
        ChipDef(id: "favs",   label: "Favs",   tint: Theme.amber,  symbol: "star.fill"),
    ]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips) { chip in
                chipButton(chip)
            }
            Spacer(minLength: 0)
            Text("\(vm.totalVisible) models")
                .font(Theme.metric(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, Theme.gutter)
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
            HStack(spacing: 4) {
                // Icon keeps its tint even when inactive — that's what makes the
                // row readable as a legend for the table's colored glyphs.
                if let symbol = chip.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(chip.tint)
                }
                Text(chip.label.uppercased())
                    .font(Theme.label(9))
                    .tracking(0.8)
                    .foregroundStyle(active ? chip.tint : Theme.textFaint)
            }
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
