import SwiftUI

/// A discovered model on a specific server.
struct DiscoveredModel: Identifiable, Hashable {
    let server: Server
    let model: LMStudioModel
    var id: String { "\(server.id)|\(model.id)" }
}

/// Model switcher (handoff §8). The trigger is a compact model chip; tapping it
/// raises a dark popover that groups models by server, shows each unit's specs,
/// and marks the loaded / selected one.
struct ModelPickerView: View {
    let discovered: [DiscoveredModel]
    @Binding var selection: DiscoveredModel?
    /// Optional callback fired when a model is selected. Return true to proceed with
    /// the selection, false to cancel (e.g., if loading failed).
    let onModelSelect: ((DiscoveredModel) async -> Bool)?
    /// Optional callback fired when the user taps the eject button on a loaded model.
    let onModelEject: ((DiscoveredModel) async -> Void)?
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
        .onHover { hovering = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ModelPickerList(groups: groups,
                            isEmpty: discovered.isEmpty,
                            selection: selection,
                            onEject: onModelEject == nil ? nil : { item in
                                Task { await onModelEject?(item) }
                            }) { item in
                Task {
                    let proceed = await onModelSelect?(item) ?? true
                    if proceed {
                        selection = item
                    }
                }
                showingPopover = false
            }
            // Force the dark theme so the popover never renders as a light system sheet.
            .preferredColorScheme(.dark)
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
    let onSelect: (DiscoveredModel) -> Void
    @State private var loadingID: String?
    @State private var ejectingID: String?
    @State private var searchText = ""
    @Environment(FavoritesStore.self) private var favorites

    private var totalCount: Int { groups.reduce(0) { $0 + $1.models.count } }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.line)
            content
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 418)
        .frame(maxHeight: 520)
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
                    .font(.mono(10)).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.line))
        .padding(13)
    }

    private func groupHeader(_ server: Server, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(server.kind == .cloudAPI ? "\(server.label.uppercased()) · CLOUD"
                                         : server.label.uppercased())
                .font(.mono(9.5)).tracking(1.2)
                .foregroundStyle(Theme.textDim)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text("\(count)")
                .font(.mono(9.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8).padding(.top, 11).padding(.bottom, 6)
    }

    private var favoritesHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text("FAVORITES")
                .font(.mono(9.5)).tracking(1.2)
                .foregroundStyle(Theme.textDim)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text("\(favoriteItems.count)")
                .font(.mono(9.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8).padding(.top, 11).padding(.bottom, 6)
    }

    /// Favorited models matching the current search, loaded models floated first.
    private var favoriteItems: [DiscoveredModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allModels = groups.flatMap { $0.models }
        let favs = allModels.filter { favorites.isFavorite($0.model.id) }
        let filtered = query.isEmpty ? favs : favs.filter {
            $0.model.familyName.localizedCaseInsensitiveContains(query)
                || $0.model.id.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { $0.model.isLoaded && !$1.model.isLoaded }
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
                                .foregroundStyle(Theme.textFaint)
                            Text("Search to add a cloud model · \(cloudModelCount) available")
                                .font(.mono(10))
                                .foregroundStyle(Theme.textFaint)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            }
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
                 }) {
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
                .foregroundStyle(Theme.textFaint)
            Eyebrow(text, color: Theme.textDim)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        SettingsLink {
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
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.012))
    }

    /// Local servers list in full; cloud catalogs stay behind search
    /// so hundreds of remote models don't dump into the popover unfiltered.
    /// Within each group, loaded models float to the top.
    private var displayGroups: [(server: Server, models: [DiscoveredModel])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        func floatLoaded(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
            models.sorted { $0.model.isLoaded && !$1.model.isLoaded }
        }

        guard !query.isEmpty else {
            return groups
                .filter { $0.server.kind != .cloudAPI }
                .map { (server: $0.server, models: floatLoaded($0.models)) }
        }
        return groups.compactMap { group in
            let matched = group.models.filter {
                $0.model.familyName.localizedCaseInsensitiveContains(query)
                    || $0.model.id.localizedCaseInsensitiveContains(query)
            }
            return matched.isEmpty ? nil : (group.server, floatLoaded(matched))
        }
    }

    private var cloudModelCount: Int {
        groups.filter { $0.server.kind == .cloudAPI }.reduce(0) { $0 + $1.models.count }
    }

    private var cloudHintVisible: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cloudModelCount > 0
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
    let onSelect: () -> Void
    @State private var hovering = false
    @Environment(FavoritesStore.self) private var favorites

    private var model: LMStudioModel { item.model }
    private var busy: Bool { isLoading || isEjecting }

    var body: some View {
        HStack(spacing: 11) {
            indicator.frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.familyName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                SpecStrip(model: model)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else {
                if let ctx = model.maxContextLength {
                    Text(contextLabel(ctx))
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                starButton
                if model.isLoaded {
                    if let onEject {
                        Button(action: onEject) {
                            Image(systemName: "eject.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textMute)
                        }
                        .buttonStyle(.plain)
                        .help("Unload model")
                    }
                } else if !isSelected {
                    Button(action: onSelect) {
                        Text("Load")
                            .font(.mono(10)).foregroundStyle(Theme.amber)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(rowFill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .contentShape(Rectangle())
        .onTapGesture { if !busy { onSelect() } }
        .onHover { hovering = $0 }
    }

    private var starButton: some View {
        let isFav = favorites.isFavorite(model.id)
        return Button {
            favorites.toggle(model.id)
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFav ? Theme.amber : Theme.textDim)
        }
        .buttonStyle(.plain)
        .help(isFav ? "Remove from favorites" : "Add to favorites")
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

    private func contextLabel(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }
}
