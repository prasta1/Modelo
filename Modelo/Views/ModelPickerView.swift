import SwiftUI

/// A discovered model on a specific server.
struct DiscoveredModel: Identifiable, Hashable {
    let server: Server
    let model: LMStudioModel
    var id: String { "\(server.id)|\(model.id)" }
}

/// Model switcher. The trigger is a compact spec plate; tapping it raises a custom
/// dark popover that groups models by machine, shows each unit's specs and
/// capabilities, and marks the loaded one — so picking feels like patching into a rack.
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
        // a lingering hover. Reset it on dismiss so the plate doesn't stay "lifted".
        .onChange(of: showingPopover) { _, open in
            if !open { hovering = false }
        }
    }

    // MARK: Trigger plate

    /// Compact header control: cube icon, selected family (or "SELECT MODEL"),
    /// the selected model's capability chips, and a chevron affordance.
    private var trigger: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 12))
                .foregroundStyle(selection == nil ? Theme.Palette.inkFaint : Theme.Palette.signal)
            if let m = selection?.model {
                Text(m.familyName)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                CapabilityChips(model: m)
            } else {
                Text("SELECT MODEL")
                    .font(Theme.label(12))
                    .tracking(1)
                    .foregroundStyle(Theme.Palette.inkDim)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .panel(hovering ? Theme.Palette.panelHigh : Theme.Palette.panel,
               radius: 8,
               stroke: selection == nil ? Theme.Palette.stroke : Theme.Palette.strokeStrong)
    }
}

/// The popover body: server-grouped, scrollable list of rich model rows on the
/// dark panel surface. Kept private to the picker so the dropdown and trigger stay
/// in lockstep.
private struct ModelPickerList: View {
    let groups: [(server: Server, models: [DiscoveredModel])]
    let isEmpty: Bool
    let selection: DiscoveredModel?
    let onEject: ((DiscoveredModel) -> Void)?
    let onSelect: (DiscoveredModel) -> Void
    @State private var loadingID: String?
    @State private var ejectingID: String?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Theme.Palette.stroke).frame(height: 1)
            content
        }
        .frame(width: 340)
        .background(Theme.Palette.panel)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.inkFaint)
            TextField("Search models", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Palette.ink)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if isEmpty {
            // Styled empty state, matching the chrome rather than a raw default string.
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkFaint)
                Eyebrow("No models on any online server", color: Theme.Palette.inkDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        } else if displayGroups.isEmpty && !cloudHintVisible {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkFaint)
                Eyebrow("No models match", color: Theme.Palette.inkDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(displayGroups, id: \.server.id) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(group.server.label)
                                .padding(.horizontal, 12)
                            ForEach(group.models) { item in
                                ModelRow(item: item,
                                         isSelected: item.id == selection?.id,
                                         isLoading: loadingID == item.id,
                                         isEjecting: ejectingID == item.id,
                                         onEject: onEject == nil ? nil : {
                                            ejectingID = item.id
                                            onEject!(item)
                                            // Auto-clear after a timeout in case the refresh
                                            // doesn't land before the popover closes.
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .seconds(5))
                                                if ejectingID == item.id { ejectingID = nil }
                                            }
                                         }) {
                                    loadingID = item.id
                                    onSelect(item)
                                    // Clear loading state after a moment so it doesn't stick
                                    // if the callback is fast; the real state updates via refreshModels()
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(0.5))
                                        if loadingID == item.id { loadingID = nil }
                                    }
                                }
                            }
                        }
                    }
                    if cloudHintVisible {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.inkFaint)
                            Text("Search to add an OpenRouter model · \(cloudModelCount) available")
                                .font(Theme.metric(10))
                                .foregroundStyle(Theme.Palette.inkFaint)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 21)
                    }
                }
                .padding(.vertical, 12)
            }
            // Cap height so long inventories scroll instead of growing off-screen.
            .frame(maxHeight: 420)
        }
    }

    /// Local servers list in full; OpenRouter's large catalog stays behind search
    /// so hundreds of cloud models don't dump into the popover unfiltered.
    private var displayGroups: [(server: Server, models: [DiscoveredModel])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return groups.filter { $0.server.kind != .openRouter }
        }
        return groups.compactMap { group in
            let matched = group.models.filter {
                $0.model.familyName.localizedCaseInsensitiveContains(query)
                    || $0.model.id.localizedCaseInsensitiveContains(query)
            }
            return matched.isEmpty ? nil : (group.server, matched)
        }
    }

    private var cloudModelCount: Int {
        groups.filter { $0.server.kind == .openRouter }.reduce(0) { $0 + $1.models.count }
    }

    private var cloudHintVisible: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cloudModelCount > 0
    }
}

/// A single rich model row in the picker dropdown: family name, spec strip,
/// capability chips, a loaded badge, and selected / hover highlighting.
private struct ModelRow: View {
    let item: DiscoveredModel
    let isSelected: Bool
    let isLoading: Bool
    let isEjecting: Bool
    let onEject: (() -> Void)?
    let onSelect: () -> Void
    @State private var hovering = false

    private var model: LMStudioModel { item.model }
    private var busy: Bool { isLoading || isEjecting }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Amber selection rail — a quiet "you are here" marker.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? Theme.Palette.signal : Color.clear)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.familyName)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.Palette.signal : Theme.Palette.ink)
                        .lineLimit(1)
                        // Truncate the name, never the trailing badge/checkmark.
                        .layoutPriority(1)
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else if isEjecting {
                        Chip(text: "ejecting…", tint: Theme.Palette.inkDim)
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else if model.isLoaded {
                        // Distinct amber "LOADED" tag — far clearer than a filled dot.
                        Chip(text: "loaded", tint: Theme.Palette.signal)
                        if let onEject {
                            Button(action: onEject) {
                                Image(systemName: "eject.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.Palette.inkDim)
                            }
                            .buttonStyle(.plain)
                            .help("Unload model")
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.signal)
                    }
                }
                SpecStrip(model: model)
                CapabilityChips(model: model)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !busy { onSelect() } }
        .padding(.horizontal, 9)
        .onHover { hovering = $0 }
    }

    /// Selected rows sit on `panelHigh`; hover lifts to the same so the cursor's
    /// position always reads, with a tint when the row is the active pick.
    private var rowFill: Color {
        if isSelected { return Theme.Palette.panelHigh }
        return hovering ? Theme.Palette.panelHigh : Color.clear
    }
}
