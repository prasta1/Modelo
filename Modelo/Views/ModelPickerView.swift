import SwiftUI
import SwiftData

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

    /// Models grouped by their server, in the user's endpoint order (`sortOrder`).
    /// Sorting here rather than trusting discovery order means a reorder shows up
    /// immediately, and the menu-bar chat (whose fetch finishes in any order) agrees.
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
        .sorted { $0.server.sortOrder < $1.server.sortOrder }
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

/// The popover body (handoff §8): search with Free / Loaded pills on top, an
/// endpoint sidebar beside a server-grouped, scrollable list of model rows, and a
/// footer holding settings and sort.
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
    @State private var renamingID: UUID?
    @State private var draggingID: UUID?
    @State private var dropTargetID: UUID?
    /// Every endpoint, including offline ones the sidebar doesn't show, so a
    /// reorder can renumber them all without colliding with hidden servers.
    @Query(sort: \Server.sortOrder) private var allServers: [Server]
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

    /// Endpoints stack vertically beside the list, so every server is visible at
    /// once instead of hiding off the end of a side-scrolling pill strip.
    /// Favorites / All / one server are mutually exclusive views.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                EndpointRow(label: "Favorites", icon: "star.fill", count: nil,
                            isActive: favoritesOnly) {
                    favoritesOnly = true
                    selectedServer = nil
                }
                EndpointRow(label: "All", icon: nil, count: totalCount,
                            isActive: !favoritesOnly && selectedServer == nil) {
                    favoritesOnly = false
                    selectedServer = nil
                }
                ForEach(Array(groups.enumerated()), id: \.element.server.id) { index, group in
                    let server = group.server
                    if renamingID == server.id {
                        EndpointRenameField(server: server) { renamingID = nil }
                    } else {
                        EndpointRow(label: server.label.isEmpty ? "Unnamed" : server.label,
                                    icon: server.kind == .cloudAPI ? "cloud" : nil,
                                    count: group.models.count,
                                    isActive: !favoritesOnly && selectedServer?.id == server.id) {
                            favoritesOnly = false
                            selectedServer = server
                        }
                        // Drag one endpoint onto another to take its slot.
                        .onDrag {
                            draggingID = server.id
                            return NSItemProvider(object: server.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: EndpointDropDelegate(
                            targetID: server.id, draggingID: $draggingID,
                            dropTargetID: $dropTargetID) { move($0, to: $1) })
                        .overlay(alignment: insertsBelow(index) ? .bottom : .top) {
                            if dropTargetID == server.id, draggingID != server.id {
                                Capsule().fill(Theme.amber)
                                    .frame(height: 2)
                                    // Sit in the 2pt gap between rows, not on the row.
                                    .offset(y: insertsBelow(index) ? 2 : -2)
                            }
                        }
                        .contextMenu {
                            Button("Rename…") { renamingID = server.id }
                            Divider()
                            Button("Move Up") { move(server.id, to: groups[index - 1].server.id) }
                                .disabled(index == 0)
                            Button("Move Down") { move(server.id, to: groups[index + 1].server.id) }
                                .disabled(index == groups.count - 1)
                        }
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
        .frame(width: 150)
        .background(Color.white.opacity(0.012))
    }

    /// True when the dragged endpoint comes from above row `index`, so it lands
    /// after that row and the insertion line belongs on the row's bottom edge.
    private func insertsBelow(_ index: Int) -> Bool {
        guard let from = groups.firstIndex(where: { $0.server.id == draggingID }) else { return false }
        return from < index
    }

    /// Moves endpoint `sourceID` into `targetID`'s slot, then renumbers every
    /// endpoint 0…n. Renumbering all of them (not just the visible ones) keeps
    /// offline servers in their relative place and clears any duplicate sortOrders.
    /// The new order also applies to Settings ▸ Endpoints, which sorts the same way.
    private func move(_ sourceID: UUID, to targetID: UUID) {
        var ordered = allServers
        guard let from = ordered.firstIndex(where: { $0.id == sourceID }),
              let to = ordered.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        // `toOffset` is the index *before* removal, so landing in a later slot needs +1.
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        for (i, server) in ordered.enumerated() { server.sortOrder = i }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                if !isEmpty {
                    sidebar
                    Divider().overlay(Theme.line)
                }
                content.frame(maxWidth: .infinity)
            }
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 560)
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
            // One-tap filters ride inside the field's right edge, so narrowing the
            // list never leaves the place you're already typing.
            Toggle("Free", isOn: $freeOnly)
                .toggleStyle(ChipToggleStyle(tint: Theme.green))
                .help("Show only free cloud models (local models always show)")
            Toggle("Loaded", isOn: $loadedOnly)
                .toggleStyle(ChipToggleStyle())
                .help("Show only models currently loaded in memory")
        }
        .padding(.leading, 12).padding(.trailing, 4).frame(height: 28)
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
                            Text("Search, or pick a cloud endpoint, to browse \(cloudModelCount) cloud models")
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
                 onEject: onEject == nil || !item.server.kind.canEject ? nil : {
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
        HStack(spacing: 6) {
            Button {
                // Close the popover, then route to Settings ▸ Endpoints in-app
                // (the Settings window no longer exists). Activating matters when
                // this picker lives in the menu-bar chat, where Modelo isn't frontmost.
                dismiss()
                settingsNavigator.open(tab: "Endpoints")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMute)
                    Text("Manage models")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textLo)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Manage models in Settings")
            Spacer()
            ModelSortMenu(sort: $sortKey)
        }
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

/// One entry in the picker's endpoint sidebar: optional icon, label, model count.
/// Active entries tint amber like a selected model row.
private struct EndpointRow: View {
    let label: String
    let icon: String?
    let count: Int?
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.mono(10))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .foregroundStyle(isActive ? Theme.amberName : Theme.textSoft)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isActive ? Theme.amberFillLo : (hovering ? Theme.fillHi : Color.clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Drop handling for one sidebar endpoint. A delegate (rather than
/// `.dropDestination`) can propose `.move`, which keeps macOS's green copy "+"
/// off the cursor, and reports enter/exit so the row can draw the insertion line.
private struct EndpointDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    let move: (UUID, UUID) -> Void

    // Only accept drags that started in this sidebar, not arbitrary text.
    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }
    func dropEntered(info: DropInfo) { dropTargetID = targetID }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil; dropTargetID = nil }
        guard let source = draggingID else { return false }
        move(source, targetID)
        return true
    }
}

/// Inline rename for a sidebar endpoint. Writes straight to `server.label` (as the
/// Settings name field does) and ends on Return or when focus leaves.
private struct EndpointRenameField: View {
    @Bindable var server: Server
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Endpoint name", text: $server.label)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textHi)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.amberBorder))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit(onDone)
            .onChange(of: focused) { _, isFocused in if !isFocused { onDone() } }
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
                        .help(model.contextHelp ?? "")
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
                     model.contextDisplay(compact: true),
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
