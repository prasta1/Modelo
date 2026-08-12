import SwiftUI

/// Fixed column widths, shared by `TableColumnHeader` and `ModelTableRow`.
/// These two must agree exactly or the header drifts out of register with the
/// rows, so they live here rather than as literals in both.
///
/// Deliberately separate from `Theme.gutter` — `star` holds the same value
/// today by coincidence, and the two answer different questions ("how wide is
/// the star column" vs "how far in does content start"). Merging them would
/// mean widening the gutter silently widened this column too.
private enum Col {
    static let star: CGFloat = 22
    /// Name is the only flexible column, but uncapped it swallowed every spare
    /// point and opened a ~230pt void between a model's name and its capability
    /// pills. Capped, the leftover goes to a spacer after the pills instead, so
    /// name + capabilities read as one group and the metrics as another.
    ///
    /// A max, not a fixed width — names shorter than this don't pad out to it,
    /// and the column still shrinks below it on a narrow window.
    ///
    /// Sized against the real catalog: of OpenRouter's 406 model names measured
    /// at SF Pro medium 11pt, the widest is 262.7pt and the next is 198.3pt, so
    /// 270 clears the single outlier with headroom to spare. Names that do
    /// overflow ellipsize (`.lineLimit(1)`) rather than break the layout, so a
    /// future long name degrades quietly — worth re-measuring if that matters.
    static let nameMax: CGFloat = 270
    static let caps: CGFloat = 148
    static let context: CGFloat = 74
    static let size: CGFloat = 56
    static let speed: CGFloat = 66
    static let used: CGFloat = 52
}

/// Dense sortable model table: sticky column header + scrollable grouped rows.
/// Columns: name (flex, capped) | capabilities | context | size | speed | used — see `Col`.
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
                    .padding(.horizontal, Theme.gutter)
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
            // Star column spacer. Height must be pinned too — Color is greedy in
            // both axes, and a height-flexible child here makes the whole header
            // stretch to split the VStack's space with the table below it.
            Color.clear.frame(width: Col.star, height: 0)

            // Name — flexible up to Col.nameMax, sortable
            sortBtn("Name", key: .name)
                .frame(maxWidth: Col.nameMax, alignment: .leading)

            // Capabilities — fixed width, not sortable
            Text("Capabilities")
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
                .frame(width: Col.caps, alignment: .leading)

            // All spare width pools here, between the name/capabilities group and
            // the metrics. Collapses to zero on a narrow window.
            Spacer(minLength: 0)

            // Fixed sortable columns
            sortBtn("Context", key: .context).frame(width: Col.context, alignment: .trailing)
            sortBtn("Size",    key: .size)   .frame(width: Col.size, alignment: .trailing)
            sortBtn("Speed",   key: .speed)  .frame(width: Col.speed, alignment: .trailing)
            sortBtn("Used",    key: .used)   .frame(width: Col.used, alignment: .trailing)
        }
        .padding(.horizontal, Theme.gutter)
        // Asymmetric on purpose: the 1pt rule below is an overlay, so it draws
        // inside these bounds. A symmetric inset leaves the labels sitting almost
        // on the line while the group header underneath gets 11pt of air.
        .padding(.top, 4)
        .padding(.bottom, 8)
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
            .frame(width: Col.star)

            // Name — flexible up to Col.nameMax
            Text(model.shortName)
                .font(Theme.metric(11))
                .foregroundStyle(isSelected ? Theme.amberName : Theme.textMid)
                .lineLimit(1)
                .frame(maxWidth: Col.nameMax, alignment: .leading)

            // Capabilities
            HStack(spacing: 3) {
                if model.isFree           { capPill("free",   Theme.green) }
                if model.supportsToolUse  { capPill("tools",  Theme.amber) }
                if model.supportsVision   { capPill("vision", Theme.blue) }
                if model.supportsThinking { capPill("reason", Theme.purple) }
                if model.isLoaded         { capPill("local",  Theme.amber) }
            }
            .frame(width: Col.caps, alignment: .leading)

            // Mirrors the header's spacer — both must be in the same position or
            // the metric columns stop lining up with their labels.
            Spacer(minLength: 0)

            // Context
            Text(contextLabel)
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(width: Col.context, alignment: .trailing)

            // Size
            Text(model.parameterSize ?? "—")
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(width: Col.size, alignment: .trailing)

            // Speed
            Text(speedLabel)
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(speedLabel == "—" ? Theme.textFaint : Theme.textLo)
                .frame(width: Col.speed, alignment: .trailing)

            // Used
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
            .frame(width: Col.used, alignment: .trailing)
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
