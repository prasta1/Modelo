import SwiftUI
import SwiftData

/// Root view for the Models page (.launcher route). Replaces LauncherView for
/// the `.launcher` sidebar route. LauncherView.swift is preserved unchanged.
struct ModelCatalogView: View {
    let discovered: [DiscoveredModel]
    let onLaunch: (DiscoveredModel) -> Void
    var onRefresh: (() async -> Void)? = nil

    @Environment(RotationStore.self)         private var rotation
    @Environment(FavoritesStore.self)        private var favorites
    @Environment(CatalogCollapseStore.self)  private var collapse

    @Query(sort: \UsageRecord.timestamp, order: .reverse)
    private var usageRecords: [UsageRecord]

    @State private var vm = ModelCatalogViewModel()
    @FocusState private var searchFocused: Bool
    @State private var showInspector = true

    var body: some View {
        ZStack {
            Theme.windowBG.ignoresSafeArea()
            VStack(spacing: 0) {
                ModelCatalogHeader(vm: vm, onRefresh: onRefresh, searchFocused: $searchFocused)
                ModelFilterChipsView(vm: vm)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        RotationTierView(vm: vm, rotation: rotation)
                        ModelTableView(vm: vm, rotation: rotation, favorites: favorites, collapse: collapse)
                    }
                    if showInspector {
                        ModelInspectorView(vm: vm, rotation: rotation, onLaunch: { model in
                            onLaunch(model)
                        })
                        .frame(width: 326)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showInspector)
            }
        }
        // Hide inspector when window is narrow
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { w in
            showInspector = w > 720
        }
        // Keyboard navigation
        .onKeyPress(.upArrow)   { vm.selectPrevious(); return .handled }
        .onKeyPress(.downArrow) { vm.selectNext();     return .handled }
        .onKeyPress(.return)    { vm.launchSelected(); return .handled }
        .onKeyPress(.escape) {
            if !vm.searchQuery.isEmpty {
                vm.searchQuery = ""
                return .handled
            }
            return .ignored
        }
        // ⌥1–⌥4 rotation slot selection
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            guard let ch = press.characters.first, let digit = Int(String(ch)), (1...4).contains(digit) else {
                return .ignored
            }
            let slot = digit - 1
            if let modelID = rotation.slots[slot],
               let item = vm.allModels.first(where: { $0.model.id == modelID }) {
                vm.selectedID = item.id
            }
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
        // ⌘K shortcut: focus search field
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Wire inputs into vm
        .onChange(of: discovered, initial: true) { _, new in
            vm.allModels = new
            vm.onLaunch = onLaunch
        }
        .onChange(of: collapse.toggled, initial: true) { _, new in
            vm.toggledGroups = new
        }
        .onChange(of: usageRecords, initial: true) { _, new in
            vm.usageRecords = new
        }
        .onChange(of: favorites.favoriteIDs, initial: true) { _, new in
            vm.favoriteIDs = new
        }
    }
}
