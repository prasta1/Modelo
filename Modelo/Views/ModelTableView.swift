import SwiftUI

/// Dense sortable model table: sticky column header + scrollable grouped rows.
/// Columns: name (flex) | capabilities 148pt | context 74pt | size 56pt | speed 66pt | used 52pt
/// BENCH column omitted — no external benchmark data source.
struct ModelTableView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let favorites: FavoritesStore

    var body: some View {
        VStack(spacing: 0) {
            // Column header — always visible, outside the ScrollView
            TableColumnHeader(vm: vm)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {

                        // LOADED ON <hostname>
                        if !vm.loadedModels.isEmpty {
                            Section {
                                ForEach(vm.loadedModels) { item in
                                    ModelTableRow(
                                        item: item,
                                        isSelected: vm.selectedID == item.id,
                                        isFavorite: favorites.isFavorite(item.model.id),
                                        speedLabel: vm.speedLabel(for: item.id),
                                        usedCount: vm.usageCount(for: item.id),
                                        onSelect: { vm.selectedID = item.id },
                                        onToggleFav: { favorites.toggle(item.model.id) }
                                    )
                                    .id(item.id)
                                }
                            } header: {
                                CatalogGroupHeader(
                                    label: "Loaded on \(vm.localHostname)".uppercased(),
                                    count: vm.loadedModels.count,
                                    isLocal: true
                                )
                            }
                        }

                        // Remote provider groups
                        ForEach(vm.groupedRemote, id: \.name) { group in
                            Section {
                                ForEach(group.models) { item in
                                    ModelTableRow(
                                        item: item,
                                        isSelected: vm.selectedID == item.id,
                                        isFavorite: favorites.isFavorite(item.model.id),
                                        speedLabel: vm.speedLabel(for: item.id),
                                        usedCount: vm.usageCount(for: item.id),
                                        onSelect: { vm.selectedID = item.id },
                                        onToggleFav: { favorites.toggle(item.model.id) }
                                    )
                                    .id(item.id)
                                }
                            } header: {
                                CatalogGroupHeader(
                                    label: group.name.uppercased(),
                                    count: group.models.count,
                                    isLocal: false
                                )
                            }
                        }

                        // Empty state
                        if vm.flatVisible.isEmpty {
                            VStack(spacing: 6) {
                                Text("Nothing matches")
                                    .font(Theme.metric(12))
                                    .foregroundStyle(Theme.textFaint)
                                if !vm.searchQuery.isEmpty {
                                    Text("\"\(vm.searchQuery)\"")
                                        .font(Theme.metric(11))
                                        .foregroundStyle(Theme.textFaint.opacity(0.55))
                                    Text("Try a different query or clear the filters above.")
                                        .font(Theme.metric(10))
                                        .foregroundStyle(Theme.textFaint.opacity(0.4))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
                .hideScrollIndicators()
                .onChange(of: vm.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Column Header

private struct TableColumnHeader: View {
    let vm: ModelCatalogViewModel

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 22)  // star column spacer

            // Name — flex, sortable
            sortBtn("Name", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Capabilities — fixed 148pt, not sortable
            Text("Capabilities")
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 148, alignment: .leading)

            // Fixed sortable columns
            sortBtn("Context", key: .context).frame(width: 74, alignment: .trailing)
            sortBtn("Size",    key: .size)   .frame(width: 56, alignment: .trailing)
            sortBtn("Speed",   key: .speed)  .frame(width: 66, alignment: .trailing)
            sortBtn("Used",    key: .used)   .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 3)
        .background(Theme.windowBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sortBtn(_ label: String, key: CatalogSort) -> some View {
        let isActive = vm.sortKey == key
        let text = isActive ? (vm.sortDescending ? "\(label) ▾" : "\(label) ▴") : label
        Button {
            if vm.sortKey == key { vm.sortDescending.toggle() }
            else { vm.sortKey = key; vm.sortDescending = true }
        } label: {
            Text(text)
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(isActive ? Theme.amber : Theme.textFaint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group Header

private struct CatalogGroupHeader: View {
    let label: String
    let count: Int
    let isLocal: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLocal ? Theme.amber : Theme.textFaint)
                .frame(width: 4, height: 4)
                .shadow(color: isLocal ? Theme.amber.opacity(0.8) : .clear, radius: 4)

            Text(label)
                .font(Theme.label(8))
                .tracking(1)
                .foregroundStyle(isLocal ? Theme.amber : Theme.textFaint)

            Spacer()

            Text("\(count) model\(count == 1 ? "" : "s")\(isLocal ? " · no network" : "")")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint.opacity(0.45))
        }
        .padding(.vertical, 7)
        .padding(.top, 4)
        .background(Theme.windowBG)
    }
}

// MARK: - Table Row

/// UNARY: single HStack root so LazyVStack can template row IDs without evaluating every body.
struct ModelTableRow: View {
    let item: DiscoveredModel
    let isSelected: Bool
    let isFavorite: Bool
    let speedLabel: String
    let usedCount: Int?
    let onSelect: () -> Void
    let onToggleFav: () -> Void

    @State private var hovering = false

    private var model: LMStudioModel { item.model }

    private var contextLabel: String {
        guard let c = model.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }

    var body: some View {
        HStack(spacing: 0) {  // UNARY root
            // Star toggle
            Button(action: onToggleFav) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isFavorite ? Theme.amber : Theme.fillHi)
            }
            .buttonStyle(.plain)
            .frame(width: 22)

            // Name (flex)
            Text(model.shortName)
                .font(Theme.metric(11))
                .foregroundStyle(isSelected ? Theme.amberName : Theme.textMid)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Capabilities (148pt)
            HStack(spacing: 3) {
                if model.isFree           { capPill("free",   Theme.green) }
                if model.supportsToolUse  { capPill("tools",  Theme.amber) }
                if model.supportsVision   { capPill("vision", Theme.blue) }
                if model.supportsThinking { capPill("reason", Theme.purple) }
                if model.isLoaded         { capPill("local",  Theme.amber) }
            }
            .frame(width: 148, alignment: .leading)

            // Context (74pt)
            Text(contextLabel)
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(width: 74, alignment: .trailing)

            // Size (56pt)
            Text(model.parameterSize ?? "—")
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(width: 56, alignment: .trailing)

            // Speed (66pt)
            Text(speedLabel)
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(speedLabel == "—" ? Theme.textFaint : Theme.textLo)
                .frame(width: 66, alignment: .trailing)

            // Used (52pt)
            Group {
                if let count = usedCount {
                    Text("\(count)×")
                } else {
                    Text("—")
                }
            }
            .font(Theme.mono(10))
            .monospacedDigit()
            .foregroundStyle(Theme.textFaint)
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.amberFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.amberBorder, lineWidth: 1)
                )
        } else if hovering {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.fillHi)
        }
    }

    @ViewBuilder private func capPill(_ label: String, _ tint: Color) -> some View {
        Text(label.uppercased())
            .font(Theme.label(7.5))
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(tint.opacity(0.32), lineWidth: 0.5)
            )
    }
}
