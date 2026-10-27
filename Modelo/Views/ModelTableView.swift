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
    /// at SF Pro medium 11pt, the widest is 262.7pt and the next is 198.3pt.
    /// Rows now render at 13pt, which scales those to ~310pt and ~234pt, so 320
    /// clears the single outlier. Names that do overflow ellipsize
    /// (`.lineLimit(1)`) rather than break the layout, so a future long name
    /// degrades quietly — worth re-measuring if that matters.
    static let nameMax: CGFloat = 320
    /// Five 14pt capability icons at 8pt spacing, plus a little air.
    static let caps: CGFloat = 108
    /// Merged metrics cell: size · speed · used×, omitting missing values.
    static let metrics: CGFloat = 148
}

/// Dense sortable model table: sticky column header + scrollable grouped rows.
/// Columns: name (flex, capped) | capabilities | context | size | speed | used — see `Col`.
/// BENCH column omitted — no external benchmark data source.
struct ModelTableView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let favorites: FavoritesStore
    let collapse: CatalogCollapseStore

    /// One model row. Extracted because it is emitted from three places
    /// (flattened, loaded, and inside a vendor group) with identical wiring.
    @ViewBuilder
    private func row(_ item: DiscoveredModel) -> some View {
        ModelTableRow(
            item: item,
            isSelected: vm.selectedID == item.id,
            isFavorite: favorites.isFavorite(item.model.id),
            speedLabel: vm.speedLabel(for: item.id),
            usedCount: vm.usageCount(for: item.id),
            onSelect: { vm.selectedID = item.id },
            onLaunch: { vm.onLaunch?(item) },
            onEject: vm.onEject.map { eject in { await eject(item) } },
            onToggleFav: { favorites.toggle(item.model.id) }
        )
        .id(item.id)
    }

    /// A vendor bucket: its header plus rows, unless collapsed.
    @ViewBuilder
    private func vendorContent(endpoint: EndpointGroup, vendor: VendorGroup) -> some View {
        // A lone unnamed bucket *is* the whole endpoint — local servers, or a
        // remote one whose IDs carry no prefix. Heading it "other" would add a
        // click and tell the reader nothing. It earns a header only when named
        // vendors sit beside it, where the loose rows would otherwise read as
        // strays above the groups.
        if vendor.name == nil, endpoint.vendors.count == 1 {
            ForEach(vendor.models) { item in
                row(item)
            }
        } else {
            let isCollapsed = vm.isVendorCollapsed(endpoint.label, vendor.id)
            VendorGroupHeader(
                name: vendor.name ?? ModelCatalogViewModel.unprefixedVendorLabel,
                count: vendor.models.count,
                isCollapsed: isCollapsed,
                onToggle: {
                    collapse.toggle(ModelCatalogViewModel.vendorKey(endpoint.label, vendor.id))
                }
            )
            if !isCollapsed {
                ForEach(vendor.models) { item in
                    row(item)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column header — always visible, outside the ScrollView
            TableColumnHeader(vm: vm)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {

                        // Metric sorts dissolve grouping into one global ranking.
                        if vm.isFlattened {
                            ForEach(vm.flatRows) { item in
                                row(item)
                            }
                        } else {
                            // LOADED ON <hostname>
                            if !vm.loadedModels.isEmpty {
                                Section {
                                    ForEach(vm.loadedModels) { item in
                                        row(item)
                                    }
                                } header: {
                                    CatalogGroupHeader(
                                        label: "Loaded on \(vm.localHostname)".uppercased(),
                                        count: vm.loadedModels.count,
                                        isLocal: true
                                    )
                                }
                            }

                            // Endpoint groups, each holding vendor sub-groups.
                            // Only the endpoint header is a Section header, so it
                            // is the one that stays pinned while scrolling; vendor
                            // headers scroll with their rows.
                            ForEach(vm.groupedRemote) { endpoint in
                                Section {
                                    if !vm.isEndpointCollapsed(endpoint.label) {
                                        ForEach(endpoint.vendors) { vendor in
                                            vendorContent(endpoint: endpoint, vendor: vendor)
                                        }
                                    }
                                } header: {
                                    CatalogGroupHeader(
                                        label: endpoint.label.uppercased(),
                                        count: endpoint.modelCount,
                                        isLocal: endpoint.isLocal,
                                        isCollapsed: vm.isEndpointCollapsed(endpoint.label),
                                        onToggle: { collapse.toggle(ModelCatalogViewModel.endpointKey(endpoint.label)) }
                                    )
                                }
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

            // Single merged metrics column header
            Text("Metrics")
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(Theme.textFaint)
                .frame(width: Col.metrics, alignment: .trailing)

            // All spare width pools after the metrics group so the content
            // cluster stays left rather than pushing metrics to the window edge.
            Spacer(minLength: 0)
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
    /// nil for the LOADED section, which has no vendor tree and never collapses.
    var isCollapsed: Bool? = nil
    var onToggle: (() -> Void)? = nil

    private var content: some View {
        HStack(spacing: 5) {
            // Reserve the gutter whether or not a chevron is drawn — the LOADED
            // section passes no chevron, and without this its label lands 13pt
            // left of every other endpoint header.
            Group {
                if let isCollapsed {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
            }
            .frame(width: 8)

            Circle()
                .fill(Theme.textFaint)
                .frame(width: 4, height: 4)

            Text(label)
                .font(Theme.label(13))
                .tracking(0.6)
                .foregroundStyle(Theme.textFaint)

            if isLocal {
                Chip(text: "local", tint: Theme.textFaint)
            }

            Spacer()

            Text("\(count) model\(count == 1 ? "" : "s")")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint.opacity(0.45))
        }
        .padding(.vertical, 7)
        .padding(.top, 4)
        .background(Theme.windowBG)
    }

    var body: some View {
        // Only a control when it can actually collapse. The LOADED section has no
        // vendor tree, so it stays plain text rather than a full-width tap target
        // that does nothing.
        if let isCollapsed, let onToggle {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label), \(count) models")
                .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
                .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        } else {
            content
        }
    }
}

// MARK: - Vendor Group Header

/// Second-level header inside an endpoint (`anthropic`, `openai`, …).
///
/// The chevron occupies the star column rather than sitting inside an inset, so
/// the vendor name lands on the same 22pt spine as the model names below it, the
/// endpoint label above it, and the `Name` column header. Indenting it instead
/// put the header 13pt to the *right* of the rows it contains — inverted nesting.
/// The rows can't move to fix that: `TableColumnHeader` reserves `Col.star`, so
/// shifting names breaks column alignment. Depth is carried by type and colour.
private struct VendorGroupHeader: View {
    let name: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textFaint.opacity(0.7))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: Col.star)

                Text(name)
                    .font(Theme.metric(10))
                    .foregroundStyle(isCollapsed ? Theme.textFaint : Theme.textMid)

                Text("\(count)")
                    .font(Theme.mono(9))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textFaint.opacity(0.5))

                Spacer()
            }
            .padding(.vertical, 5)
            .background(hovering ? Theme.fillHi : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count) models")
        .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .onHover { hovering = $0 }
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
    let onLaunch: () -> Void
    /// Unloads this model. Only offered while it is loaded.
    let onEject: (() async -> Void)?
    let onToggleFav: () -> Void

    @State private var hovering = false
    @State private var ejecting = false

    private var model: LMStudioModel { item.model }

    /// size · speed t/s · count×, omitting whichever values are unavailable.
    private var metricsLabel: String {
        var parts: [String] = []
        if let sz = model.parameterSize { parts.append(sz) }
        if speedLabel != "—" { parts.append(speedLabel + " t/s") }
        if let count = usedCount { parts.append("\(count)×") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
                .font(Theme.metric(13))
                .foregroundStyle(isSelected ? Theme.amberName : Theme.textMid)
                .lineLimit(1)
                .frame(maxWidth: Col.nameMax, alignment: .leading)

            // Capabilities
            HStack(spacing: 8) {
                if model.isFree           { capIcon("gift",                    "Free",      Theme.green) }
                if model.supportsToolUse  { capIcon("wrench.and.screwdriver", "Tool use",  Theme.amber) }
                if model.supportsVision   { capIcon("eye",                     "Vision",    Theme.blue) }
                if model.supportsThinking { capIcon("brain",                   "Reasoning", Theme.purple) }
                if model.isLoaded         { capIcon("memorychip",              "Loaded",    Theme.green) }
            }
            .frame(width: Col.caps, alignment: .leading)

            // Merged metrics: size · speed · used×
            Text(metricsLabel)
                .font(Theme.mono(11))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(width: Col.metrics, alignment: .trailing)
                .lineLimit(1)

            // Unload a loaded model without leaving the list.
            if model.isLoaded, let onEject {
                Button {
                    ejecting = true
                    Task {
                        await onEject()
                        ejecting = false
                    }
                } label: {
                    if ejecting {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMute)
                    }
                }
                .buttonStyle(.plain)
                .disabled(ejecting)
                .frame(width: 28)
                .help("Unload model")
                .accessibilityLabel("Unload \(model.shortName)")
            }

            // Mirrors the header's spacer — absorbs spare width after metrics
            // so the content cluster stays left rather than spreading edge-to-edge.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onLaunch() }
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help("Double-click to open in new chat")
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

    /// A tinted capability glyph. Shape carries the meaning, so it still reads
    /// with Differentiate Without Color on; the name lives in the tooltip and
    /// the VoiceOver label.
    private func capIcon(_ symbol: String, _ label: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 14)
            .help(label)
            .accessibilityLabel(label)
    }
}
