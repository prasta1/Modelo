import SwiftUI

/// A discovered model on a specific server.
struct DiscoveredModel: Identifiable, Hashable {
    let server: Server
    let model: LMStudioModel
    var id: String { "\(server.id)|\(model.id)" }
}

// MARK: - Sort

/// User-selectable ordering for the model panes. Shared between the launcher grid
/// and the switcher popover via a single @AppStorage key.
enum ModelSort: String, CaseIterable, Identifiable {
    case name, family, size, parameters

    static let storageKey = "modelSortKey"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:       "Name"
        case .family:     "Family"
        case .size:       "Size"
        case .parameters: "Parameters"
        }
    }

    /// Returns true when `a` should sort before `b`. Name/Family: ascending;
    /// Size/Parameters: descending (largest first). Unknown values sort last.
    func ascending(_ a: LMStudioModel, _ b: LMStudioModel) -> Bool {
        switch self {
        case .name:
            return a.familyName.localizedCaseInsensitiveCompare(b.familyName) == .orderedAscending
        case .family:
            let fa = a.familyTag ?? "\u{10FFFF}"
            let fb = b.familyTag ?? "\u{10FFFF}"
            let cmp = fa.localizedCaseInsensitiveCompare(fb)
            guard cmp == .orderedSame else { return cmp == .orderedAscending }
            return a.familyName.localizedCaseInsensitiveCompare(b.familyName) == .orderedAscending
        case .size:
            switch (a.fileSizeBytes, b.fileSizeBytes) {
            case (nil, _): return false
            case (_, nil): return true
            case let (sa?, sb?): return sa > sb
            }
        case .parameters:
            switch (Self.paramBillions(a), Self.paramBillions(b)) {
            case (nil, _): return false
            case (_, nil): return true
            case let (pa?, pb?): return pa > pb
            }
        }
    }

    /// "7B" → 7.0, nil when the id has no embedded param count.
    private static func paramBillions(_ m: LMStudioModel) -> Double? {
        guard let s = m.parameterSize else { return nil }
        return Double(s.dropLast())
    }
}

// MARK: - Sort menu

/// Compact sort control shared by the launcher grid and the switcher popover.
struct ModelSortMenu: View {
    @Binding var sort: ModelSort

    var body: some View {
        Menu {
            ForEach(ModelSort.allCases) { option in
                Button { sort = option } label: {
                    if sort == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .medium))
                Text(sort.label)
                    .font(Theme.label(9))
                    .tracking(0.8)
            }
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Model switcher (handoff §8). The trigger is a compact model chip; tapping it
/// raises a dark popover that groups models by server, shows each unit's specs,
/// and marks the loaded / selected one.
struct ModelPickerView: View {
    let discovered: [DiscoveredModel]
    @Binding var selection: DiscoveredModel?
    /// Optional callback fired after a model is selected, for best-effort warm-up
    /// (e.g. LM Studio load-on-select + a model refresh). The return value is ignored;
    /// selection happens regardless so a failed load never blocks picking a model.
    let onModelSelect: ((DiscoveredModel) async -> Bool)?
    /// Optional callback fired when the user taps the eject button on a loaded model.
    let onModelEject: ((DiscoveredModel) async -> Void)?
    /// Optional callback fired when the user double-clicks a model row to start a new chat.
    let onNewChat: (() -> Void)?
    @State private var hovering = false
    @State private var showingPopover = false

    /// Models grouped by their server, preserving discovery order of servers.
    private var groups: [(server: Server, models: [DiscoveredModel])] {
        var order: [UUID] = []
        var byServer: [UUID: [DiscoveredModel]] = [:]
        for item in discovered {
            if byServer[item.server.id] == nil { order.append(item.server.id) }
            byServer[item.server.id, default: []].append(item)
        }
        return order.compactMap { id in
            guard let first = byServer[id]?.first else { return nil }
            return (first.server, byServer[id]!)
        }
    }

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch model")
        .onHover { hovering = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ModelPickerList(groups: groups,
                            isEmpty: discovered.isEmpty,
                            selection: selection,
                            onEject: onModelEject == nil ? nil : { item in
                                Task { await onModelEject?(item) }
                            },
                            onNewChat: onNewChat) { item in
                // Reflect the pick immediately. Selection must NOT be gated on the
                // load below: an OpenAI-compatible server (oMLX, vLLM…) classified as
                // LM Studio can't be "loaded" and would otherwise fail, leaving the
                // chat with no model and a "pick a model before sending" error.
                selection = item
                showingPopover = false
                // Best-effort warm-up (LM Studio load-on-select); its result no longer
                // affects whether the model is selected.
                if let onModelSelect {
                    Task { _ = await onModelSelect(item) }
                }
            }
            // Force the dark theme so the popover never renders as a light system sheet.
            .preferredColorScheme(Theme.active.scheme)
        }
        // The trigger sits behind the open popover, so `onHover` can't fire to clear
        // a lingering hover. Reset it on dismiss so the chip doesn't stay "lifted".
        .onChange(of: showingPopover) { _, open in
            if !open { hovering = false }
        }
    }

    // MARK: Trigger — Native Refined model chip

    /// Compact header chip: a green presence dot, the selected family (or
    /// "SELECT MODEL"), and a chevron affordance.
    private var trigger: some View {
        HStack(spacing: 9) {
            if let m = selection?.model {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text(m.familyName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textHi)
            } else {
                Text("SELECT MODEL")
                    .font(.mono(11)).tracking(1)
                    .foregroundStyle(Theme.textMute)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textMute)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(hovering ? Theme.fillHi : Theme.fill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .stroke(Color.white.opacity(0.09)))
    }
}

/// The popover body (handoff §8): server-grouped, scrollable list of model rows
/// on the dark popover surface, with a search field and a settings footer.
private struct ModelPickerList: View {
    let groups: [(server: Server, models: [DiscoveredModel])]
    let isEmpty: Bool
    let selection: DiscoveredModel?
    let onEject: ((DiscoveredModel) -> Void)?
    let onNewChat: (() -> Void)?
    let onSelect: (DiscoveredModel) -> Void
    @State private var loadingID: String?
    @State private var ejectingID: String?
    @State private var searchText = ""
    @State private var selectedServer: Server? = nil
    @State private var freeOnly = false
    @State private var loadedOnly = false
    @State private var favoritesOnly = false
    @AppStorage(ModelSort.storageKey) private var sortKey: ModelSort = .name
    @Environment(FavoritesStore.self) private var favorites
    @Environment(SettingsNavigator.self) private var settingsNavigator
    @Environment(\.dismiss) private var dismiss

    private var totalCount: Int { groups.reduce(0) { $0 + $1.models.count } }

    /// True when the item should be shown given the current free-only toggle.
    /// Local models always pass (they're free to run); cloud models must have isFree set.
    private func passesFree(_ item: DiscoveredModel) -> Bool {
        !freeOnly || item.server.kind.isLocal || item.model.isFree
    }

    /// Server pills scroll on the left; the filter + sort menus stay pinned right,
    /// so every control lives in one band instead of three stacked strips.
    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if groups.count > 1 {
                        FilterPill(label: "All", isActive: selectedServer == nil) {
                            selectedServer = nil
                        }
                        ForEach(groups, id: \.server.id) { group in
                            FilterPill(
                                label: group.server.label,
                                isActive: selectedServer?.id == group.server.id
                            ) {
                                selectedServer = selectedServer?.id == group.server.id ? nil : group.server
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            filterMenu
            ModelSortMenu(sort: $sortKey)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 10)
    }

    /// Loaded / Favorites / Free toggles folded into one menu; the label tints
    /// amber and shows a count while any of them is on.
    private var filterMenu: some View {
        let active = [loadedOnly, favoritesOnly, freeOnly].filter { $0 }.count
        return Menu {
            Toggle("Loaded", isOn: $loadedOnly)
            Toggle("Favorites", isOn: $favoritesOnly)
            Toggle("Free", isOn: $freeOnly)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .medium))
                Text(active == 0 ? "Filter" : "Filter · \(active)")
                    .font(Theme.label(9))
                    .tracking(0.8)
            }
            .foregroundStyle(active == 0 ? Theme.textDim : Theme.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active == 0 ? Theme.fill : Theme.amberFill, in: Capsule())
            .overlay(Capsule().strokeBorder(active == 0 ? Theme.line : Theme.amberBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterBar
            Divider().overlay(Theme.line)
            content
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 440)
        .frame(maxHeight: 560)
        .background(Theme.popoverBG)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("Search models…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textHi)
            if searchText.isEmpty {
                Text("\(totalCount)")
                    .font(.mono(10)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.line))
        .padding(13)
    }

    private func groupHeader(_ server: Server, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(server.kind == .cloudAPI ? "\(server.label.uppercased()) · CLOUD"
                                         : server.label.uppercased())
                // Small-caps section label (popover convention), quieter than the
                // 13pt model names it sits over.
                .font(Theme.label(11)).tracking(1)
                .foregroundStyle(Theme.textDim)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text("\(count)")
                .font(.mono(10)).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 5)
    }

    private var favoritesHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text("FAVORITES")
                .font(Theme.label(11)).tracking(1)
                .foregroundStyle(Theme.textDim)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text("\(favoriteItems.count)")
                .font(.mono(10)).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 5)
    }

    /// Favorited models matching the current search + filters, loaded models floated first.
    private var favoriteItems: [DiscoveredModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allModels = groups.flatMap { $0.models }
        var favs = allModels.filter { favorites.isFavorite($0.model.id) }
        if let srv = selectedServer { favs = favs.filter { $0.server.id == srv.id } }
        if loadedOnly { favs = favs.filter { $0.model.isLoaded } }
        let filtered = (query.isEmpty ? favs : favs.filter {
            $0.model.familyName.localizedCaseInsensitiveContains(query)
                || $0.model.id.localizedCaseInsensitiveContains(query)
        }).filter { passesFree($0) }
        // Sort: loaded first, then by user sort key. Deduplicate by model ID across servers.
        var seen = Set<String>()
        return filtered
            .sorted { a, b in
                if a.model.isLoaded != b.model.isLoaded { return a.model.isLoaded }
                return sortKey.ascending(a.model, b.model)
            }
            .filter { seen.insert($0.model.id).inserted }
    }

    @ViewBuilder private var content: some View {
        if isEmpty {
            emptyState(icon: "cube.transparent", text: "No models on any online server")
        } else if displayGroups.isEmpty && !cloudHintVisible && favoriteItems.isEmpty {
            emptyState(icon: "magnifyingglass", text: "No models match")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !favoriteItems.isEmpty {
                        favoritesHeader
                        ForEach(favoriteItems) { item in
                            modelRow(for: item)
                        }
                    }
                    ForEach(displayGroups, id: \.server.id) { group in
                        groupHeader(group.server, count: group.models.count)
                        ForEach(group.models) { item in
                            modelRow(for: item)
                        }
                    }
                    if cloudHintVisible {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textDim)
                            Text("Search to add a cloud model · \(cloudModelCount) available")
                                .font(.mono(10))
                                .foregroundStyle(Theme.textDim)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
                .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Builds a `ModelRow` wired to the shared loading/ejecting state.
    private func modelRow(for item: DiscoveredModel) -> some View {
        ModelRow(item: item,
                 isSelected: item.id == selection?.id,
                 isLoading: loadingID == item.id,
                 isEjecting: ejectingID == item.id,
                 onEject: onEject == nil ? nil : {
                    ejectingID = item.id
                    onEject!(item)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        if ejectingID == item.id { ejectingID = nil }
                    }
                 },
                 onNewChat: onNewChat) {
            loadingID = item.id
            onSelect(item)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                if loadingID == item.id { loadingID = nil }
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Eyebrow(text, color: Theme.textDim)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        Button {
            // Close the popover, then route to Settings ▸ Endpoints in-app
            // (the Settings window no longer exists).
            dismiss()
            settingsNavigator.open(tab: "Endpoints")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMute)
                Text("Manage models")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textLo)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Manage models in Settings")
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.012))
    }

    /// Local servers list in full; cloud catalogs stay behind search
    /// so hundreds of remote models don't dump into the popover unfiltered.
    /// Within each group, loaded models float to the top, then sorted by sortKey.
    private var displayGroups: [(server: Server, models: [DiscoveredModel])] {
        // When favoritesOnly is on, the favorites section shows everything; hide server groups.
        if favoritesOnly { return [] }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        func sortAndFloat(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
            models.sorted { a, b in
                if a.model.isLoaded != b.model.isLoaded { return a.model.isLoaded }
                return sortKey.ascending(a.model, b.model)
            }
        }

        func applyFilters(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
            models.filter { passesFree($0) && (!loadedOnly || $0.model.isLoaded) }
        }

        func matchesServer(_ group: (server: Server, models: [DiscoveredModel])) -> Bool {
            guard let srv = selectedServer else { return true }
            return group.server.id == srv.id
        }

        guard !query.isEmpty else {
            return groups
                // When a specific server is selected or free filter is on, show cloud groups too.
                .filter { selectedServer != nil || freeOnly || $0.server.kind != .cloudAPI }
                .filter { matchesServer($0) }
                .compactMap { group in
                    let visible = sortAndFloat(applyFilters(group.models))
                    return visible.isEmpty ? nil : (group.server, visible)
                }
        }
        return groups
            .filter { matchesServer($0) }
            .compactMap { group in
                let matched = applyFilters(group.models.filter {
                    $0.model.familyName.localizedCaseInsensitiveContains(query)
                        || $0.model.id.localizedCaseInsensitiveContains(query)
                })
                return matched.isEmpty ? nil : (group.server, sortAndFloat(matched))
            }
    }

    private var cloudModelCount: Int {
        groups.filter { $0.server.kind == .cloudAPI }.reduce(0) { $0 + $1.models.count }
    }

    private var cloudHintVisible: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cloudModelCount > 0
            && selectedServer == nil
            && !freeOnly
            && !favoritesOnly
    }
}

/// A single model row (handoff §8): a state indicator, family name + spec strip,
/// a context label, and a Load / eject affordance. Selected rows tint amber.
private struct ModelRow: View {
    let item: DiscoveredModel
    let isSelected: Bool
    let isLoading: Bool
    let isEjecting: Bool
    let onEject: (() -> Void)?
    let onNewChat: (() -> Void)?
    let onSelect: () -> Void
    @State private var hovering = false
    @Environment(FavoritesStore.self) private var favorites

    private var model: LMStudioModel { item.model }
    private var busy: Bool { isLoading || isEjecting }

    var body: some View {
        HStack(spacing: 8) {
            indicator.frame(width: 16)

            // Specs ride on a second line so the name gets the full row width
            // instead of competing with four fixed metric columns.
            VStack(alignment: .leading, spacing: 2) {
                Text(model.familyName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if let specLine {
                    Text(specLine)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions appear on hover only; a favorite's filled star and an in-flight
            // spinner stay visible because they're state, not controls. Fixed frames
            // keep the name column stable whether or not anything renders.
            Group { if hovering || isFavorite { starButton } }.frame(width: 20)
            Group { if hovering || busy { actionArea } }.frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(rowFill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !busy { onSelect(); onNewChat?() } }
        .onTapGesture { if !busy { onSelect() } }
        .onHover { hovering = $0 }
        .help("Select \(model.familyName) · Double-click to open in new chat")
        // VoiceOver can't hover or double-click, so the hidden buttons and the
        // double-click shortcut are re-exposed as named actions.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if let onNewChat {
                Button("Open in new chat") { if !busy { onSelect(); onNewChat() } }
            }
            Button(isFavorite ? "Remove from favorites" : "Add to favorites") {
                favorites.toggle(model.id)
            }
            if model.isLoaded, let onEject {
                Button("Unload model", action: onEject)
            }
        }
    }

    /// "7B · Q4_K_M · 32K · 4.2 GB", skipping unknown values; nil when none are known.
    private var specLine: String? {
        let parts = [model.parameterSize,
                     model.quantization,
                     model.contextDisplay,
                     model.displaySizeFormatted].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var actionArea: some View {
        if busy {
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        } else if model.isLoaded, let onEject {
            Button(action: onEject) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textMute)
            }
            .buttonStyle(.plain)
            .help("Unload model")
            .accessibilityLabel("Unload \(model.familyName)")
        } else if !isSelected {
            // Only LM Studio loads on select (handleModelSelection). Everywhere else this
            // just picks the model, so don't promise a load that won't happen.
            let loadsOnSelect = item.server.kind == .lmStudio
            Button(action: onSelect) {
                Text(loadsOnSelect ? "Load" : "Use")
                    .font(.mono(10)).foregroundStyle(Theme.amber)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(loadsOnSelect ? "Load this model"
                  : item.server.kind == .llamaSwap
                    ? "Select this model — llama-swap loads it when you send your first message"
                    : "Select this model")
        }
    }

    private var isFavorite: Bool { favorites.isFavorite(model.id) }

    private var starButton: some View {
        let isFav = isFavorite
        return Button {
            favorites.toggle(model.id)
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFav ? Theme.amber : Theme.textDim)
        }
        .buttonStyle(.plain)
        .help(isFav ? "Remove from favorites" : "Add to favorites")
        .accessibilityLabel(isFav ? "Remove from favorites" : "Add to favorites")
    }

    @ViewBuilder private var indicator: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.amber)
        } else if model.isLoaded {
            Circle().fill(Theme.green).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.greenGlow, lineWidth: 3))
        } else if item.server.kind == .cloudAPI {
            Image(systemName: "cloud")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMute)
        } else {
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                .frame(width: 7, height: 7)
        }
    }

    private var nameColor: Color {
        if isSelected { return Theme.amberName }
        if model.isLoaded { return Theme.textHi }
        return Theme.textSoft
    }

    /// Selected rows tint amber; hover lifts to a faint fill.
    private var rowFill: Color {
        if isSelected { return Theme.amberFillLo }
        return hovering ? Theme.fillHi : Color.clear
    }
}
