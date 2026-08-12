# Model Catalog Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `LauncherView` (the `.launcher` sidebar route) with a new `ModelCatalogView` featuring a rotation tier, dense sortable table, and detail inspector — all on the existing `model-picker-explosion` branch, no commit, no merge.

**Architecture:** `ModelCatalogViewModel` (`@Observable @MainActor`) owns all filter/sort/selection state and caches derived collections. `RotationStore` (`@Observable @MainActor`) holds 4 ordered pinned-model slots in `UserDefaults`. Eight focused View files compose the full page; `ContentView`'s `launcher` computed property is swapped to instantiate `ModelCatalogView` instead of `LauncherView`.

**Tech Stack:** SwiftUI (macOS 15+), SwiftData (`@Query` for `UsageRecord`), `@Observable`, existing `Theme.*` tokens, `LazyVStack(pinnedViews:)` + `ScrollViewReader` for the table, `onKeyPress` for keyboard nav.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Modelo/Modelo/Services/RotationStore.swift` | **Create** | 4-slot ordered pinned-model list, UserDefaults persistence |
| `Modelo/Modelo/Services/ModelCatalogViewModel.swift` | **Create** | Filter/sort/selection state, cached derived lists, speed medians, usage stats, nav helpers |
| `Modelo/Modelo/Views/ModelCatalogHeader.swift` | **Create** | Search field + sort pill + refresh icon |
| `Modelo/Modelo/Views/ModelFilterChipsView.swift` | **Create** | ALL / FREE / TOOLS / VISION / REASON / LOADED / FAVS chip row |
| `Modelo/Modelo/Views/RotationTierView.swift` | **Create** | Section label + 4-card grid + `RotationCardView` |
| `Modelo/Modelo/Views/ModelTableView.swift` | **Create** | Column header row + `ScrollView`/`LazyVStack` + `ModelTableRow` + group headers |
| `Modelo/Modelo/Views/ModelInspectorView.swift` | **Create** | Right panel: spec rows, history histogram, compare mode, sticky footer |
| `Modelo/Modelo/Views/ModelCatalogView.swift` | **Create** | Root composition, keyboard wiring, inspector hide/show |
| `Modelo/Modelo/ModeloApp.swift` | **Modify** | Add `@State private var rotationStore = RotationStore()` + inject into environment |
| `Modelo/Modelo/ContentView.swift` | **Modify** | Swap `launcher` computed property to use `ModelCatalogView`; add `@Environment(RotationStore.self)` |

**Not touched:** `LauncherView.swift`, `ModelBrowserView.swift`, `ModelPickerView.swift`, sidebar, chat view, settings, or any other existing file.

---

## Task 1: RotationStore

**Files:**
- Create: `Modelo/Modelo/Services/RotationStore.swift`

- [ ] **Step 1.1 — Create `RotationStore.swift`**

```swift
import Foundation

/// Ordered list of up to 4 pinned model IDs (DiscoveredModel.id). Slot index
/// maps directly to ⌥1–⌥4. nil = empty slot.
@Observable @MainActor
final class RotationStore {
    private static let key = "rotationModelSlots"

    private(set) var slots: [String?] = [nil, nil, nil, nil]

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        slots = (0..<4).map { i in
            guard i < stored.count else { return nil }
            return stored[i].isEmpty ? nil : stored[i]
        }
    }

    // MARK: - Mutations

    func pin(_ modelID: String) {
        if slots.contains(modelID) { return }
        if let i = slots.firstIndex(where: { $0 == nil }) {
            slots[i] = modelID
        } else {
            slots[3] = modelID  // replace last slot when full
        }
        persist()
    }

    func unpin(_ modelID: String) {
        guard let i = slots.firstIndex(of: modelID) else { return }
        slots[i] = nil
        persist()
    }

    // MARK: - Queries

    func slot(for modelID: String) -> Int? {
        slots.firstIndex(of: modelID)
    }

    func isPinned(_ modelID: String) -> Bool {
        slots.contains(modelID)
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(slots.map { $0 ?? "" }, forKey: Self.key)
    }
}
```

- [ ] **Step 1.2 — Verify the file compiles in isolation**

  Use `XcodeRefreshCodeIssuesInFile` on `Modelo/Modelo/Services/RotationStore.swift`. Expected: no errors.

---

## Task 2: ModelCatalogViewModel

**Files:**
- Create: `Modelo/Modelo/Services/ModelCatalogViewModel.swift`

- [ ] **Step 2.1 — Create `ModelCatalogViewModel.swift`**

```swift
import Foundation
import SwiftData

/// Sort keys for the model catalog table.
enum CatalogSort: String, CaseIterable, Identifiable {
    case speed, name, context, used, size
    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed:   "Speed"
        case .name:    "Name"
        case .context: "Context"
        case .used:    "Used"
        case .size:    "Size"
        }
    }
}

/// All filter/sort/selection state for `ModelCatalogView`. Derived collections
/// (loadedModels, groupedRemote, flatVisible) are cached in `didSet` so
/// `ForEach` never sorts/filters inline.
@Observable @MainActor
final class ModelCatalogViewModel {

    // MARK: - Inputs (set by view on appear/change)

    var allModels: [DiscoveredModel] = []   { didSet { recompute() } }
    var usageRecords: [UsageRecord] = []    { didSet { recomputeUsage(); recompute() } }
    var favoriteIDs: Set<String> = []       { didSet { recompute() } }

    // MARK: - Filter / sort state

    var searchQuery: String = ""            { didSet { recompute() } }
    var activeFilters: Set<String> = []     { didSet { recompute() } }
    var sortKey: CatalogSort = .name        { didSet { recompute() } }
    var sortDescending: Bool = true         { didSet { recompute() } }

    // MARK: - Selection

    var selectedID: String? {
        didSet {
            if let old = oldValue, old != selectedID { previousSelectedID = old }
        }
    }
    private(set) var previousSelectedID: String?

    // MARK: - Cached derived collections

    private(set) var loadedModels: [DiscoveredModel] = []
    private(set) var groupedRemote: [(name: String, models: [DiscoveredModel])] = []
    private(set) var flatVisible: [DiscoveredModel] = []  // for ↑/↓ nav

    // MARK: - Usage-derived stats (keyed by LMStudioModel.id)

    private(set) var speedMedians: [String: Double] = [:]
    private(set) var usageCounts: [String: Int] = [:]
    private(set) var lastUsedDates: [String: Date] = [:]
    private(set) var weeklyHistograms: [String: [Int]] = [:]  // 12 buckets, index 0 = 12 weeks ago

    // MARK: - Callback

    var onLaunch: ((DiscoveredModel) -> Void)?

    // MARK: - Derived helpers

    var selectedModel: DiscoveredModel? { allModels.first { $0.id == selectedID } }
    var previousModel: DiscoveredModel? {
        guard let prev = previousSelectedID else { return nil }
        return allModels.first { $0.id == prev }
    }

    var localHostname: String { Host.current().localizedName ?? "this Mac" }

    var totalVisible: Int { flatVisible.count }
    var totalAll: Int { allModels.count }

    // MARK: - Navigation

    func selectNext() {
        guard !flatVisible.isEmpty else { return }
        if let id = selectedID, let idx = flatVisible.firstIndex(where: { $0.id == id }) {
            selectedID = flatVisible[min(idx + 1, flatVisible.count - 1)].id
        } else {
            selectedID = flatVisible.first?.id
        }
    }

    func selectPrevious() {
        guard !flatVisible.isEmpty else { return }
        if let id = selectedID, let idx = flatVisible.firstIndex(where: { $0.id == id }) {
            selectedID = flatVisible[max(idx - 1, 0)].id
        } else {
            selectedID = flatVisible.last?.id
        }
    }

    func launchSelected() {
        guard let model = selectedModel else { return }
        onLaunch?(model)
    }

    // MARK: - Inspector helpers

    /// Formatted speed for a given DiscoveredModel.id (via model.id).
    func speedLabel(for discoveredID: String) -> String {
        guard let item = allModels.first(where: { $0.id == discoveredID }),
              let v = speedMedians[item.model.id] else { return "—" }
        return "\(Int(v))"
    }

    func usageCount(for discoveredID: String) -> Int? {
        guard let item = allModels.first(where: { $0.id == discoveredID }) else { return nil }
        return usageCounts[item.model.id]
    }

    func histogram(for discoveredID: String) -> [Int] {
        guard let item = allModels.first(where: { $0.id == discoveredID }) else { return Array(repeating: 0, count: 12) }
        return weeklyHistograms[item.model.id] ?? Array(repeating: 0, count: 12)
    }

    func lastUsedLabel(for discoveredID: String) -> String? {
        guard let item = allModels.first(where: { $0.id == discoveredID }),
              let date = lastUsedDates[item.model.id] else { return nil }
        let interval = Date().timeIntervalSince(date)
        if interval < 3600  { return "\(max(1, Int(interval / 60)))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    func speedRank(for discoveredID: String) -> (rank: Int, total: Int)? {
        guard let item = allModels.first(where: { $0.id == discoveredID }),
              speedMedians[item.model.id] != nil else { return nil }
        let withSpeed = allModels.filter { speedMedians[$0.model.id] != nil }
        let sorted = withSpeed.sorted { (speedMedians[$0.model.id] ?? 0) > (speedMedians[$1.model.id] ?? 0) }
        guard let rank = sorted.firstIndex(where: { $0.id == discoveredID }) else { return nil }
        return (rank + 1, allModels.count)
    }

    func contextRankLabel(for discoveredID: String) -> String? {
        guard let item = allModels.first(where: { $0.id == discoveredID }),
              let ctx = item.model.maxContextLength else { return nil }
        let total = allModels.count
        guard total > 0 else { return nil }
        let betterCount = allModels.filter { ($0.model.maxContextLength ?? 0) > ctx }.count
        let pct = Int(Double(betterCount + 1) / Double(total) * 100)
        return "top \(pct)%"
    }

    var maxSpeedMedian: Double { speedMedians.values.max() ?? 1 }
    var maxContextLength: Int { allModels.compactMap { $0.model.maxContextLength }.max() ?? 1 }

    // MARK: - Recompute

    private func recomputeUsage() {
        var byModel: [String: [Double]] = [:]
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]

        for r in usageRecords {
            counts[r.modelID, default: 0] += 1
            if r.tokensPerSecond > 0 {
                byModel[r.modelID, default: []].append(r.tokensPerSecond)
            }
            if let prev = latest[r.modelID] {
                if r.timestamp > prev { latest[r.modelID] = r.timestamp }
            } else {
                latest[r.modelID] = r.timestamp
            }
        }

        speedMedians = byModel.mapValues { values in
            let s = values.sorted()
            let m = s.count / 2
            return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2.0 : s[m]
        }
        usageCounts = counts
        lastUsedDates = latest

        let cal = Calendar.current
        let now = Date()
        var histos: [String: [Int]] = [:]
        for r in usageRecords {
            let w = cal.dateComponents([.weekOfYear], from: r.timestamp, to: now).weekOfYear ?? 999
            if w >= 0, w < 12 {
                if histos[r.modelID] == nil { histos[r.modelID] = Array(repeating: 0, count: 12) }
                histos[r.modelID]![11 - w] += 1
            }
        }
        weeklyHistograms = histos
    }

    private func recompute() {
        let filtered = applyFilters(allModels)
        let sorted = applySort(filtered)

        let loaded = sorted.filter { $0.model.isLoaded }
        let notLoaded = sorted.filter { !$0.model.isLoaded }

        var groupMap: [String: [DiscoveredModel]] = [:]
        var groupOrder: [String] = []
        for item in notLoaded {
            let key = item.server.label
            if groupMap[key] == nil {
                groupMap[key] = []
                groupOrder.append(key)
            }
            groupMap[key]!.append(item)
        }

        loadedModels = loaded
        groupedRemote = groupOrder.compactMap { name -> (name: String, models: [DiscoveredModel])? in
            guard let models = groupMap[name], !models.isEmpty else { return nil }
            return (name: name, models: models)
        }
        flatVisible = loaded + notLoaded
    }

    private func applyFilters(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
        let terms = parseQuery(searchQuery)
        return models.filter { item in
            let m = item.model
            if activeFilters.contains("free")   && !item.server.kind.isLocal && !m.isFree          { return false }
            if activeFilters.contains("tools")  && !m.supportsToolUse                              { return false }
            if activeFilters.contains("vision") && !m.supportsVision                               { return false }
            if activeFilters.contains("reason") && !m.supportsThinking                             { return false }
            if activeFilters.contains("loaded") && !m.isLoaded                                     { return false }
            if activeFilters.contains("favs")   && !favoriteIDs.contains(item.id)                  { return false }

            for term in terms {
                switch term {
                case .ctxGT(let v):
                    guard let c = m.maxContextLength, c >= v else { return false }
                case .ctxLT(let v):
                    if let c = m.maxContextLength, c > v { return false }
                case .speedGT(let v):
                    if (speedMedians[m.id] ?? 0) < v { return false }
                case .speedLT(let v):
                    if (speedMedians[m.id] ?? 0) > v { return false }
                case .usedGT(let v):
                    if (usageCounts[m.id] ?? 0) <= v { return false }
                case .cap(let cap):
                    switch cap {
                    case "free":   if !m.isFree           { return false }
                    case "tools":  if !m.supportsToolUse  { return false }
                    case "vision": if !m.supportsVision   { return false }
                    case "reason": if !m.supportsThinking { return false }
                    case "loaded": if !m.isLoaded         { return false }
                    default: break
                    }
                case .nameMatch(let q):
                    if !m.id.localizedCaseInsensitiveContains(q) &&
                       !m.shortName.localizedCaseInsensitiveContains(q) { return false }
                }
            }
            return true
        }
    }

    private func applySort(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
        models.sorted { a, b in
            let result: Bool
            switch sortKey {
            case .name:
                result = a.model.shortName.localizedCaseInsensitiveCompare(b.model.shortName) == .orderedAscending
            case .speed:
                result = (speedMedians[a.model.id] ?? -1) > (speedMedians[b.model.id] ?? -1)
            case .context:
                result = (a.model.maxContextLength ?? 0) > (b.model.maxContextLength ?? 0)
            case .used:
                result = (usageCounts[a.model.id] ?? 0) > (usageCounts[b.model.id] ?? 0)
            case .size:
                result = (a.model.fileSizeBytes ?? 0) > (b.model.fileSizeBytes ?? 0)
            }
            return sortDescending ? result : !result
        }
    }

    // MARK: - Query parsing

    private enum QueryTerm {
        case ctxGT(Int), ctxLT(Int)
        case speedGT(Double), speedLT(Double)
        case usedGT(Int)
        case cap(String)
        case nameMatch(String)
    }

    private func parseQuery(_ raw: String) -> [QueryTerm] {
        raw.lowercased()
            .split(separator: " ")
            .map(String.init)
            .map { t in
                if t.hasPrefix("ctx>"),   let v = parseKMB(String(t.dropFirst(4))) { return .ctxGT(v) }
                if t.hasPrefix("ctx<"),   let v = parseKMB(String(t.dropFirst(4))) { return .ctxLT(v) }
                if t.hasPrefix("speed>"), let v = Double(t.dropFirst(6))            { return .speedGT(v) }
                if t.hasPrefix("speed<"), let v = Double(t.dropFirst(6))            { return .speedLT(v) }
                if t.hasPrefix("used>"),  let v = Int(t.dropFirst(5))               { return .usedGT(v) }
                let caps = ["free", "tools", "vision", "reason", "loaded"]
                if caps.contains(t)                                                  { return .cap(t) }
                return .nameMatch(t)
            }
    }

    private func parseKMB(_ s: String) -> Int? {
        let l = s.lowercased()
        if l.hasSuffix("k"), let n = Double(l.dropLast()) { return Int(n * 1_000) }
        if l.hasSuffix("m"), let n = Double(l.dropLast()) { return Int(n * 1_000_000) }
        return Int(l)
    }
}
```

- [ ] **Step 2.2 — Verify in Xcode**

  Use `XcodeRefreshCodeIssuesInFile` on `Modelo/Modelo/Services/ModelCatalogViewModel.swift`. Expected: no errors. If `DiscoveredModel` is flagged as undefined, verify the file is in the Modelo target (it's defined in `ModelPickerView.swift`, same target). It will resolve at build time.

---

## Task 3: ModelCatalogHeader + ModelFilterChipsView

**Files:**
- Create: `Modelo/Modelo/Views/ModelCatalogHeader.swift`
- Create: `Modelo/Modelo/Views/ModelFilterChipsView.swift`

- [ ] **Step 3.1 — Create `ModelCatalogHeader.swift`**

```swift
import SwiftUI

/// Band 1: search field, sort pill, icon button.
struct ModelCatalogHeader: View {
    let vm: ModelCatalogViewModel
    var onRefresh: (() async -> Void)? = nil
    @FocusState.Binding var searchFocused: Bool
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 10) {
            searchField
            sortPill
            if let onRefresh {
                refreshButton(onRefresh)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Text("⌕")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)
            TextField("Search models — or type ctx>200k tools speed>85", text: Bindable(vm).searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textMid)
                .focused($searchFocused)
                .onSubmit { }
            Spacer(minLength: 0)
            Text("\(vm.totalVisible) of \(vm.totalAll)")
                .font(Theme.metric(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
            Text("⌘K")
                .font(Theme.code(9))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private var sortPill: some View {
        Menu {
            ForEach(CatalogSort.allCases) { sort in
                Button(sort.label) { vm.sortKey = sort }
            }
        } label: {
            Text("\(vm.sortKey.label) ▾")
                .font(Theme.label(9))
                .tracking(0.5)
                .foregroundStyle(Theme.textMid)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .fixedSize()
    }

    private func refreshButton(_ action: @escaping () async -> Void) -> some View {
        Button {
            isRefreshing = true
            Task { await action(); isRefreshing = false }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: isRefreshing
                )
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .disabled(isRefreshing)
    }
}
```

- [ ] **Step 3.2 — Create `ModelFilterChipsView.swift`**

```swift
import SwiftUI

/// Band 2: capability + utility filter chips.
struct ModelFilterChipsView: View {
    let vm: ModelCatalogViewModel

    private struct ChipDef {
        let key: String
        let label: String
        let tint: Color
    }

    private let chips: [ChipDef] = [
        ChipDef(key: "all",    label: "All",    tint: .clear),   // special: clears all
        ChipDef(key: "free",   label: "Free",   tint: Theme.green),
        ChipDef(key: "tools",  label: "Tools",  tint: Theme.amber),
        ChipDef(key: "vision", label: "Vision", tint: Theme.blue),
        ChipDef(key: "reason", label: "Reason", tint: Theme.purple),
        ChipDef(key: "loaded", label: "Loaded", tint: Theme.green),
        ChipDef(key: "favs",   label: "Favs",   tint: Theme.amber),
    ]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips, id: \.key) { chip in
                chipView(chip)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func chipView(_ chip: ChipDef) -> some View {
        let isAll = chip.key == "all"
        let active = isAll ? vm.activeFilters.isEmpty : vm.activeFilters.contains(chip.key)
        let tint: Color = isAll ? Theme.amber : chip.tint

        Button {
            if isAll {
                vm.activeFilters.removeAll()
            } else {
                if vm.activeFilters.contains(chip.key) {
                    vm.activeFilters.remove(chip.key)
                } else {
                    vm.activeFilters.insert(chip.key)
                }
            }
        } label: {
            Text(chip.label.uppercased())
                .font(Theme.label(9))
                .tracking(0.8)
                .foregroundStyle(active ? tint : Theme.textFaint)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    active ? tint.opacity(0.09) : Color.clear,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        active ? tint.opacity(0.35) : Theme.line,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3.3 — Verify both files**

  Use `XcodeRefreshCodeIssuesInFile` on each. Expected: no errors.

---

## Task 4: RotationTierView

**Files:**
- Create: `Modelo/Modelo/Views/RotationTierView.swift`

- [ ] **Step 4.1 — Create `RotationTierView.swift`**

This file contains `RotationTierView` (the section) and `RotationCardView` (individual card):

```swift
import SwiftUI

/// Section label + 4-card horizontal grid for pinned rotation models.
struct RotationTierView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore

    private func item(for slot: Int) -> DiscoveredModel? {
        guard let id = rotation.slots[slot] else { return nil }
        return vm.allModels.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Eyebrow("Your Rotation", color: Theme.textFaint, size: 9)
                Text("⌥1–4 to switch mid-chat")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.5))
            }
            .padding(.horizontal, 22)

            HStack(spacing: 9) {
                ForEach(0..<4, id: \.self) { slot in
                    RotationCardView(
                        slotIndex: slot,
                        item: item(for: slot),
                        isSelected: item(for: slot).map { $0.id == vm.selectedID } ?? false,
                        vm: vm
                    )
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

/// One rotation slot: filled card or dashed empty placeholder.
private struct RotationCardView: View {
    let slotIndex: Int
    let item: DiscoveredModel?
    let isSelected: Bool
    let vm: ModelCatalogViewModel

    var body: some View {
        Group {
            if let item {
                FilledRotationCard(slotIndex: slotIndex, item: item, isSelected: isSelected, vm: vm)
            } else {
                EmptyRotationCard(slotIndex: slotIndex)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FilledRotationCard: View {
    let slotIndex: Int
    let item: DiscoveredModel
    let isSelected: Bool
    let vm: ModelCatalogViewModel

    private var model: LMStudioModel { item.model }

    private var placementLabel: String {
        if model.isLoaded             { return "Loaded" }
        if item.server.kind.isLocal   { return "Cold" }
        return "Remote"
    }

    private var dotColor: Color {
        if model.isLoaded             { return Theme.amber }
        if item.server.kind.isLocal   { return Theme.textFaint }
        return Theme.green
    }

    private var speedText: String {
        vm.speedLabel(for: item.id) == "—" ? "—" : "\(vm.speedLabel(for: item.id)) t/s"
    }

    private var contextText: String {
        guard let c = model.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }

    /// Last 8 of the 12-week histogram buckets.
    private var sparkBars: [Int] {
        let full = vm.histogram(for: item.id)
        return Array(full.suffix(8))
    }

    private var maxBar: Int { sparkBars.max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Top row: status dot + label, key hint
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: dotColor.opacity(model.isLoaded ? 0.9 : 0), radius: 4)
                    Text(placementLabel.uppercased())
                        .font(Theme.label(8))
                        .tracking(0.6)
                        .foregroundStyle(dotColor)
                }
                Spacer()
                Text("⌥\(slotIndex + 1)")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.5))
            }

            // Model name
            Text(model.shortName)
                .font(Theme.metric(11))
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Theme.amber : Theme.textMid)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metrics line
            Text([speedText, contextText, model.parameterSize].compactMap { $0 == "—" ? nil : $0 }.joined(separator: "  ·  "))
                .font(Theme.mono(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)

            // Bottom: sparkline + use count
            HStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(sparkBars.indices, id: \.self) { i in
                        let frac = maxBar > 0 ? Double(sparkBars[i]) / Double(maxBar) : 0
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(isSelected ? Theme.amber.opacity(0.35 + frac * 0.65)
                                             : Theme.fillHi.opacity(0.5 + frac * 0.5))
                            .frame(width: 5, height: max(2, 12 * frac))
                    }
                }
                Spacer()
                if let count = vm.usageCount(for: item.id), count > 0 {
                    Text("\(count)×")
                        .font(Theme.metric(9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textFaint.opacity(0.5))
                }
            }
            .frame(height: 14)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            isSelected ? Theme.amberFill : Theme.fill,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.amberBorder : Theme.line,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { vm.selectedID = item.id }
    }
}

private struct EmptyRotationCard: View {
    let slotIndex: Int

    var body: some View {
        VStack {
            Spacer()
            Text("⌥\(slotIndex + 1)  ·  Pin a model")
                .font(Theme.metric(9))
                .foregroundStyle(Theme.textFaint.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Theme.line.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
    }
}
```

- [ ] **Step 4.2 — Verify**

  Use `XcodeRefreshCodeIssuesInFile` on `RotationTierView.swift`. Expected: no errors.

---

## Task 5: ModelTableView

**Files:**
- Create: `Modelo/Modelo/Views/ModelTableView.swift`

This file contains: `ModelTableView`, `TableColumnHeader`, `CatalogGroupHeader`, `ModelTableRow`, and the `capPill` helper.

**Note: BENCH column is dropped** — no external benchmark data source exists. Table columns are: `name (flex) | capabilities 148pt | context 74pt | size 56pt | speed 66pt | used 52pt`.

- [ ] **Step 5.1 — Create `ModelTableView.swift`**

```swift
import SwiftUI

/// Dense sortable model table: sticky column header + scrollable grouped rows.
struct ModelTableView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let favorites: FavoritesStore

    var body: some View {
        VStack(spacing: 0) {
            TableColumnHeader(vm: vm)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // LOADED ON <hostname> group
                        if !vm.loadedModels.isEmpty {
                            Section {
                                ForEach(vm.loadedModels) { item in
                                    ModelTableRow(
                                        item: item,
                                        isSelected: vm.selectedID == item.id,
                                        isFavorite: favorites.isFavorite(item.id),
                                        speedLabel: vm.speedLabel(for: item.id),
                                        usedCount: vm.usageCount(for: item.id),
                                        onSelect: { vm.selectedID = item.id },
                                        onToggleFav: { favorites.toggle(item.id) }
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
                                        isFavorite: favorites.isFavorite(item.id),
                                        speedLabel: vm.speedLabel(for: item.id),
                                        usedCount: vm.usageCount(for: item.id),
                                        onSelect: { vm.selectedID = item.id },
                                        onToggleFav: { favorites.toggle(item.id) }
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
                                        .foregroundStyle(Theme.textFaint.opacity(0.6))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        }
                    }
                    .padding(.horizontal, 22)
                    .hideScrollIndicators()
                }
                .scrollIndicators(.hidden)
                .onChange(of: vm.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

/// Sticky column header row (lives outside the ScrollView, always visible).
private struct TableColumnHeader: View {
    let vm: ModelCatalogViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Padding for star icon column
            Color.clear.frame(width: 20)

            headerCell("Name", flex: true, key: .name)
            headerCell("Capabilities", width: 148, key: nil)
            headerCell("Context", width: 74, key: .context, align: .trailing)
            headerCell("Size", width: 56, key: .size, align: .trailing)
            headerCell("Speed", width: 66, key: .speed, align: .trailing)
            headerCell("Used", width: 52, key: .used, align: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 5)
        .background(Theme.windowBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func headerCell(
        _ label: String,
        flex: Bool = false,
        width: CGFloat? = nil,
        key: CatalogSort?,
        align: HorizontalAlignment = .leading
    ) -> some View {
        let isActive = key != nil && vm.sortKey == key

        Button {
            if let key {
                if vm.sortKey == key {
                    vm.sortDescending.toggle()
                } else {
                    vm.sortKey = key
                    vm.sortDescending = true
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(isActive ? (vm.sortDescending ? "\(label) ▾" : "\(label) ▴") : label)
                    .font(Theme.label(8))
                    .tracking(0.8)
                    .foregroundStyle(isActive ? Theme.amber : Theme.textFaint)
            }
            .frame(maxWidth: flex ? .infinity : nil, minWidth: width, maxWidth: width, alignment: .init(horizontal: align, vertical: .center))
        }
        .buttonStyle(.plain)
        .disabled(key == nil)
    }
}

/// Sticky section divider for a model group.
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

            Text("\(count) models\(isLocal ? " · no network" : "")")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint.opacity(0.5))
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 7)
        .padding(.top, 4)
        .background(Theme.windowBG)
    }
}

/// One table row. UNARY: single HStack root so ForEach can template row ids.
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
            .frame(width: 20)

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
                if let count = usedCount, count > 0 {
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
        .padding(.horizontal, 2)
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
```

- [ ] **Step 5.2 — Verify**

  Use `XcodeRefreshCodeIssuesInFile` on `ModelTableView.swift`. Expected: no errors.

---

## Task 6: ModelInspectorView

**Files:**
- Create: `Modelo/Modelo/Views/ModelInspectorView.swift`

Spec rows: SPEED, CONTEXT, SIZE, COST (BENCH dropped — no data source). Compare mode shows a two-column diff of the same 4 rows.

- [ ] **Step 6.1 — Create `ModelInspectorView.swift`**

```swift
import SwiftUI

/// 326pt right panel: model detail + compare mode.
struct ModelInspectorView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let onLaunch: (DiscoveredModel) -> Void

    @State private var comparing = false

    var body: some View {
        VStack(spacing: 0) {
            if let model = vm.selectedModel {
                if comparing, let prev = vm.previousModel {
                    ComparePanel(model1: model, model2: prev, vm: vm, onClose: { comparing = false })
                } else {
                    DetailPanel(
                        model: model,
                        vm: vm,
                        rotation: rotation,
                        compareCandidate: vm.previousModel,
                        onOpenCompare: { comparing = true },
                        onLaunch: onLaunch
                    )
                }
            } else {
                InspectorPlaceholder()
            }
        }
        .background(Theme.sidebarBG)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.line).frame(width: 1)
        }
        .onChange(of: vm.selectedID) { comparing = false }
    }
}

// MARK: - Detail Panel

private struct DetailPanel: View {
    let model: DiscoveredModel
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let compareCandidate: DiscoveredModel?
    let onOpenCompare: () -> Void
    let onLaunch: (DiscoveredModel) -> Void

    private var m: LMStudioModel { model.model }

    private var placementLine: String {
        if m.isLoaded           { return "LOADED · \(vm.localHostname.uppercased())" }
        if model.server.kind.isLocal { return "NOT LOADED" }
        return "REMOTE · \(model.server.label.uppercased())"
    }

    private var placementColor: Color {
        if m.isLoaded           { return Theme.amber }
        if model.server.kind.isLocal { return Theme.textFaint }
        return Theme.green
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Placement
                    HStack(spacing: 5) {
                        Circle().fill(placementColor)
                            .frame(width: 5, height: 5)
                            .shadow(color: m.isLoaded ? placementColor.opacity(0.9) : .clear, radius: 4)
                        Text(placementLine)
                            .font(Theme.label(8))
                            .tracking(0.8)
                            .foregroundStyle(placementColor)
                    }
                    .padding(.bottom, 7)

                    // Name + sub
                    Text(m.shortName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .lineLimit(3)
                        .padding(.bottom, 2)

                    Text([m.publisher, m.quantization, m.arch].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.metric(9))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .padding(.bottom, 10)

                    // Capability pills
                    HStack(spacing: 4) {
                        if m.isFree           { Chip(text: "free",   tint: Theme.green) }
                        if m.supportsToolUse  { Chip(text: "tools",  tint: Theme.amber) }
                        if m.supportsVision   { Chip(text: "vision", tint: Theme.blue) }
                        if m.supportsThinking { Chip(text: "reason", tint: Theme.purple) }
                        if m.isLoaded         { Chip(text: "local",  tint: Theme.amber) }
                    }
                    .padding(.bottom, 14)

                    // Spec rows
                    specRows
                        .padding(.bottom, 14)

                    // History
                    historyBlock
                        .padding(.bottom, 12)

                    // Compare affordance
                    if let prev = compareCandidate {
                        Button(action: onOpenCompare) {
                            HStack {
                                Text("Compare with \(prev.model.shortName)")
                                    .font(Theme.metric(9))
                                    .foregroundStyle(Theme.textFaint)
                                Spacer()
                                Text("Open")
                                    .font(Theme.label(9))
                                    .foregroundStyle(Theme.amber)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Theme.amberBorder, lineWidth: 1)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(11)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        )
                        .padding(.bottom, 12)
                    }
                }
                .padding(18)
                .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)

            // Sticky footer
            inspectorFooter
        }
    }

    // MARK: Spec rows

    @ViewBuilder private var specRows: some View {
        VStack(spacing: 0) {
            // SPEED
            if let rank = vm.speedRank(for: model.id) {
                let spd = vm.speedMedians[m.id] ?? 0
                let frac = vm.maxSpeedMedian > 0 ? spd / vm.maxSpeedMedian : 0
                SpecRow(label: "Speed",
                        value: "\(Int(spd)) tok/s",
                        rank: "\(rank.rank)\(ordinal(rank.rank)) of \(rank.total)",
                        barFrac: frac,
                        barAccent: true)
            } else {
                SpecRow(label: "Speed", value: "—", rank: nil, barFrac: 0, barAccent: true)
            }
            // CONTEXT
            let ctxFrac: Double = {
                guard let c = m.maxContextLength, vm.maxContextLength > 0
                else { return 0 }
                return Double(c) / Double(vm.maxContextLength)
            }()
            SpecRow(label: "Context",
                    value: contextLabel,
                    rank: vm.contextRankLabel(for: model.id),
                    barFrac: ctxFrac,
                    barAccent: false)

            // SIZE
            let sizeStr = m.displaySizeFormatted ?? m.parameterSize.map { "\($0)" } ?? "—"
            SpecRow(label: "Size",
                    value: sizeStr,
                    rank: nil,
                    barFrac: sizeFrac,
                    barAccent: false)

            // COST
            SpecRow(label: "Cost",
                    value: m.isLoaded ? "free — runs on your Mac" : (m.isFree ? "free" : "paid"),
                    rank: nil,
                    barFrac: 0,
                    barAccent: false)
        }
    }

    private var contextLabel: String {
        guard let c = m.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }

    private var sizeFrac: Double {
        guard let bytes = m.fileSizeBytes else { return 0 }
        let maxBytes = vm.allModels.compactMap { $0.model.fileSizeBytes }.max() ?? 1
        return maxBytes > 0 ? Double(bytes) / Double(maxBytes) : 0
    }

    // MARK: History block

    @ViewBuilder private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.bottom, 10)

            let count = vm.usageCount(for: model.id) ?? 0
            Text("\(count)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .monospacedDigit()

            let lastStr = vm.lastUsedLabel(for: model.id) ?? "never"
            Text("chats · last used \(lastStr)")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint)
                .padding(.bottom, 8)

            // 12-bar histogram
            let bars = vm.histogram(for: model.id)
            let maxBar = bars.max() ?? 1
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bars.indices, id: \.self) { i in
                    let frac = maxBar > 0 ? Double(bars[i]) / Double(maxBar) : 0
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.amber.opacity(0.25 + frac * 0.75))
                        .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 26 * frac + 2)
                }
            }
            .frame(height: 28)

            Text("12 weeks")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint.opacity(0.5))
        }
    }

    // MARK: Footer

    private var inspectorFooter: some View {
        HStack(spacing: 7) {
            Button {
                onLaunch(model)
            } label: {
                HStack(spacing: 6) {
                    Text("New chat")
                    Text("⏎")
                        .font(Theme.mono(11))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0F0F13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                if rotation.isPinned(model.id) {
                    rotation.unpin(model.id)
                } else {
                    rotation.pin(model.id)
                }
            } label: {
                Text(rotation.isPinned(model.id) ? "Unpin" : "Pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMid)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Theme.sidebarBG)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "th"
        default:
            switch n % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }
}

// MARK: - Spec Row

private struct SpecRow: View {
    let label: String
    let value: String
    let rank: String?
    let barFrac: Double
    let barAccent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label.uppercased())
                    .font(Theme.label(7.5))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textFaint.opacity(0.5))
                    .frame(width: 56, alignment: .leading)
                Text(value)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textLo)
                    .monospacedDigit()
                if let rank {
                    Spacer()
                    Text(rank)
                        .font(Theme.metric(8))
                        .foregroundStyle(Theme.textFaint.opacity(0.5))
                }
            }
            if barFrac > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill).frame(height: 3)
                        Capsule()
                            .fill(barAccent ? Theme.amber : Color.white.opacity(0.22))
                            .frame(width: geo.size.width * barFrac, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
        }
    }
}

// MARK: - Compare Panel

private struct ComparePanel: View {
    let model1: DiscoveredModel
    let model2: DiscoveredModel
    let vm: ModelCatalogViewModel
    let onClose: () -> Void

    private var m1: LMStudioModel { model1.model }
    private var m2: LMStudioModel { model2.model }

    private var speed1: Double { vm.speedMedians[m1.id] ?? 0 }
    private var speed2: Double { vm.speedMedians[m2.id] ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m1.shortName).font(Theme.metric(10)).foregroundStyle(Theme.textHi).lineLimit(1)
                    Text(m2.shortName).font(Theme.metric(10)).foregroundStyle(Theme.textMid).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Text("✕ close")
                        .font(Theme.label(9))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    compareRow("Speed",
                               v1: speed1 > 0 ? "\(Int(speed1)) t/s" : "—",
                               v2: speed2 > 0 ? "\(Int(speed2)) t/s" : "—",
                               winner: speed1 > speed2 ? 0 : (speed2 > speed1 ? 1 : nil))

                    compareRow("Context",
                               v1: ctxLabel(m1), v2: ctxLabel(m2),
                               winner: (m1.maxContextLength ?? 0) > (m2.maxContextLength ?? 0) ? 0 :
                                       (m2.maxContextLength ?? 0) > (m1.maxContextLength ?? 0) ? 1 : nil)

                    compareRow("Size",
                               v1: m1.displaySizeFormatted ?? "—",
                               v2: m2.displaySizeFormatted ?? "—",
                               winner: nil)  // no clear winner for size

                    compareRow("Cost",
                               v1: m1.isFree ? "free" : "paid",
                               v2: m2.isFree ? "free" : "paid",
                               winner: m1.isFree && !m2.isFree ? 0 : !m1.isFree && m2.isFree ? 1 : nil)

                    // Verdict
                    verdictView
                        .padding(.top, 14)
                }
                .padding(18)
                .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private func compareRow(_ label: String, v1: String, v2: String, winner: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.label(7.5))
                .tracking(0.5)
                .foregroundStyle(Theme.textFaint.opacity(0.5))
            HStack {
                Text(v1)
                    .font(Theme.mono(10))
                    .foregroundStyle(winner == 0 ? Theme.amber : Theme.textLo)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(v2)
                    .font(Theme.mono(10))
                    .foregroundStyle(winner == 1 ? Theme.amber : Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
        }
    }

    @ViewBuilder private var verdictView: some View {
        let parts = verdictParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " "))
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verdictParts: [String] {
        var parts: [String] = []
        let name1 = m1.familyName
        let name2 = m2.familyName
        if speed1 > 0 && speed2 > 0 {
            let diff = abs(Int(speed1) - Int(speed2))
            if diff > 0 {
                let faster = speed1 > speed2 ? name1 : name2
                parts.append("\(faster) is \(diff) tok/s faster.")
            }
        }
        if let c1 = m1.maxContextLength, let c2 = m2.maxContextLength, c1 != c2 {
            let bigger = c1 > c2 ? name1 : name2
            parts.append("\(bigger) has a larger context window.")
        }
        return parts
    }

    private func ctxLabel(_ m: LMStudioModel) -> String {
        guard let c = m.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }
}

// MARK: - Placeholder

private struct InspectorPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Select a model")
                .font(Theme.metric(13))
                .foregroundStyle(Theme.textFaint)
            Text("Use ↑↓ or click a row")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 6.2 — Verify**

  Use `XcodeRefreshCodeIssuesInFile` on `ModelInspectorView.swift`. Expected: no errors. If `Color(hex:)` or `Theme.code()` flag, they're defined in `Theme.swift` — will resolve at build.

---

## Task 7: ModelCatalogView (Root)

**Files:**
- Create: `Modelo/Modelo/Views/ModelCatalogView.swift`

- [ ] **Step 7.1 — Create `ModelCatalogView.swift`**

```swift
import SwiftUI
import SwiftData

/// Root view for the Models page (.launcher route). Replaces LauncherView.
/// LauncherView.swift is preserved unchanged.
struct ModelCatalogView: View {
    // Inputs matching the old LauncherView signature
    let discovered: [DiscoveredModel]
    let onLaunch: (DiscoveredModel) -> Void
    var onRefresh: (() async -> Void)? = nil

    @Environment(RotationStore.self)  private var rotation
    @Environment(FavoritesStore.self) private var favorites

    @Query(sort: \UsageRecord.timestamp, order: .reverse)
    private var usageRecords: [UsageRecord]

    @State private var vm = ModelCatalogViewModel()
    @FocusState private var searchFocused: Bool
    @State private var showInspector = true
    @State private var listHasFocus = false

    var body: some View {
        ZStack {
            Theme.windowBG.ignoresSafeArea()
            VStack(spacing: 0) {
                ModelCatalogHeader(
                    vm: vm,
                    onRefresh: onRefresh,
                    searchFocused: $searchFocused
                )

                ModelFilterChipsView(vm: vm)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        RotationTierView(vm: vm, rotation: rotation)
                        ModelTableView(vm: vm, rotation: rotation, favorites: favorites)
                    }

                    if showInspector {
                        ModelInspectorView(
                            vm: vm,
                            rotation: rotation,
                            onLaunch: onLaunch
                        )
                        .frame(width: 326)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showInspector)
            }
        }
        // Hide inspector at narrow widths
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { w in
            showInspector = w > 720
        }
        // Keyboard navigation
        .onKeyPress(.upArrow)   { vm.selectPrevious(); return .handled }
        .onKeyPress(.downArrow) { vm.selectNext();     return .handled }
        .onKeyPress(.return)    { vm.launchSelected(); return .handled }
        .onKeyPress(.escape)    {
            if !vm.searchQuery.isEmpty { vm.searchQuery = "" }
            return .handled
        }
        // ⌥1–⌥4 rotation selection
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.option),
                  let digit = press.characters.first.flatMap({ Int(String($0)) }),
                  (1...4).contains(digit) else { return .ignored }
            let slot = digit - 1
            if let id = rotation.slots[slot],
               let item = vm.allModels.first(where: { $0.id == id }) {
                vm.selectedID = item.id
            }
            return .handled
        }
        .focusable()
        // ⌘K focuses the search field
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
        .onChange(of: usageRecords, initial: true) { _, new in
            vm.usageRecords = new
        }
        .onChange(of: favorites.favoriteIDs, initial: true) { _, new in
            vm.favoriteIDs = new
        }
    }
}
```

- [ ] **Step 7.2 — Verify**

  Use `XcodeRefreshCodeIssuesInFile` on `ModelCatalogView.swift`. Expected: no errors.

---

## Task 8: Wire into ModeloApp + ContentView

**Files:**
- Modify: `Modelo/Modelo/ModeloApp.swift` — add RotationStore
- Modify: `Modelo/Modelo/ContentView.swift` — swap launcher computed property

- [ ] **Step 8.1 — Add RotationStore to ModeloApp**

In `ModeloApp.swift`, after line 17 (`@State private var favoritesStore = FavoritesStore()`), add:

```swift
    @State private var rotationStore = RotationStore()
```

In `body`, after `.environment(favoritesStore)` (line 110), add:

```swift
                .environment(rotationStore)
```

Also add `.environment(rotationStore)` in the `MenuBarExtra` chain after `.environment(favoritesStore)` (line 177).

- [ ] **Step 8.2 — Swap ContentView's launcher computed property**

In `ContentView.swift`, find the `launcher` computed property (lines 262–272). Replace **only** `LauncherView(` with `ModelCatalogView(`. The full replacement:

Find:
```swift
    private var launcher: some View {
        LauncherView(
            discovered: discoveredWithLiveState,
            endpointFilter: $endpointFilter,
            onLaunch: { model in Task { await launch(model: model) } },
            onUnload: handleModelEject,
            onPin: { item in await handleModelPin(server: item.server, modelID: item.model.id) },
            onUnpin: { item in await handleModelUnpin(server: item.server, modelID: item.model.id) },
            onRefresh: { await refreshModels() }
        )
    }
```

Replace with:
```swift
    private var launcher: some View {
        ModelCatalogView(
            discovered: discoveredWithLiveState,
            onLaunch: { model in Task { await launch(model: model) } },
            onRefresh: { await refreshModels() }
        )
    }
```

Note: `ModelCatalogView` doesn't take `endpointFilter`, `onUnload`, `onPin`, or `onUnpin` — filtering by server is now handled by the search query syntax. `LauncherView` remains untouched.

Also add `RotationStore` environment read in `ContentView`. Find the existing `@Environment(FavoritesStore.self)` line in `ContentView.swift` and add below it:

```swift
    @Environment(RotationStore.self) private var rotationStore
```

(ContentView doesn't directly use `rotationStore` — the environment just flows through to `ModelCatalogView`.)

- [ ] **Step 8.3 — Verify both files**

  Use `XcodeRefreshCodeIssuesInFile` on `ContentView.swift`. Expected: no errors. Use `XcodeRefreshCodeIssuesInFile` on `ModeloApp.swift`. Expected: no errors.

---

## Task 9: Build and Fix

- [ ] **Step 9.1 — Full project build**

  Use `BuildProject` on the Modelo scheme. Target: macOS. Review all errors carefully before attempting fixes.

- [ ] **Step 9.2 — Common fixes to expect**

  *If `RotationStore` is not in scope inside `ModelCatalogView`:* ensure `RotationStore.swift` is added to the Modelo target (Xcode project membership). Use `XcodeGlob` to confirm it appears in the project.

  *If `CatalogSort` conflict with existing `ModelSort`:* both enums can coexist — they have different names. If a type clash occurs, prefix `CatalogSort` → `ModelCatalogSort` everywhere it appears in `ModelCatalogViewModel.swift`, `ModelCatalogHeader.swift`, and `ModelCatalogView.swift`.

  *If `Server.kind.isLocal` does not compile:* read `Modelo/Modelo/Models/Server.swift` to check the exact property name, then update the three references in `ModelCatalogViewModel.swift` and `RotationTierView.swift`.

  *If `favorites.toggle(item.id)` fails:* `FavoritesStore.toggle()` takes a `modelID: String` that is the raw `LMStudioModel.id`. Update calls in `ModelTableView.swift` to `favorites.toggle(item.model.id)` and `favorites.isFavorite(item.model.id)`.

  *If `Bindable(vm).searchQuery` in `ModelCatalogHeader.swift` fails:* change to pass `vm` as `@Bindable var vm: ModelCatalogViewModel` in the struct and use `$vm.searchQuery`.

- [ ] **Step 9.3 — Smoke test in the app**

  Use `RunProject` to launch Modelo. Navigate to Models in the sidebar. Confirm:
  - Three-band layout renders (header + chips + body split)
  - Rotation tier shows 4 slots (empty dashed cards until models are pinned)
  - Table shows loaded group + provider groups with model rows
  - Clicking a row populates the inspector
  - Inspector footer "New chat" button starts a chat
  - "Pin" button fills a rotation slot
  - Search field filters the table as you type

- [ ] **Step 9.4 — Keyboard smoke test**

  With Models page focused:
  - Press `⌘K` → search field should focus
  - Press `↓` → selection should move to first row
  - Press `↓` again → selection moves down
  - Press `↑` → moves back up
  - Press `⏎` → starts a new chat with selected model
  - Press `Esc` with query text → clears the query

---

## Acceptance Checklist

- [ ] No new font families, sizes, or weights (all use `Theme.label()`, `Theme.metric()`, `Theme.mono()`, `Theme.code()`)
- [ ] No new color literals (all use `Theme.*` tokens or `Theme.Palette.*`)
- [ ] Rotation tier renders above table, outside any ScrollView
- [ ] `ModelTableRow` has a single `HStack` root (unary for ForEach fast path)
- [ ] Sort/filter computed in `ModelCatalogViewModel.recompute()` via `didSet`, never inline in `ForEach`
- [ ] Table rows scroll; rotation cards and column header are fixed/visible at all times
- [ ] Inspector hides at window width < 720pt
- [ ] `LauncherView.swift` unchanged and still compiles
- [ ] No `git add`, no `git commit`, no `git push` (branch only)
