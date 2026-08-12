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

/// A vendor bucket inside an endpoint (`anthropic`, `openai`, …).
///
/// `name` is nil for models whose IDs carry no `org/` prefix — local servers —
/// which render directly under the endpoint with no intermediate level rather
/// than inside a pointless one-bucket group.
struct VendorGroup: Identifiable {
    let name: String?
    let models: [DiscoveredModel]
    var id: String { name ?? "" }
}

/// One registered endpoint and its models, bucketed by vendor.
struct EndpointGroup: Identifiable {
    let label: String
    let isLocal: Bool
    /// Total across all vendors, shown on the header while collapsed.
    let modelCount: Int
    let vendors: [VendorGroup]
    var id: String { label }
}

/// All filter/sort/selection state for ModelCatalogView. Derived collections
/// are cached in didSet so ForEach never sorts/filters inline.
@Observable @MainActor
final class ModelCatalogViewModel {

    // MARK: - Inputs (set by view on appear/change)

    var allModels: [DiscoveredModel] = []    { didSet { recompute() } }
    var usageRecords: [UsageRecord] = []     { didSet { recomputeUsage(); recompute() } }
    var favoriteIDs: Set<String> = []        { didSet { recompute() } }
    /// Group keys the user has toggled away from their default state, mirrored in
    /// from `CatalogCollapseStore`. Drives which rows exist at all, so it has to
    /// recompute — collapsed rows must not be reachable by keyboard either.
    var toggledGroups: Set<String> = []      { didSet { recompute() } }

    // MARK: - Filter / sort state

    var searchQuery: String = ""             { didSet { recompute() } }
    var activeFilters: Set<String> = []      { didSet { recompute() } }
    var sortKey: CatalogSort = .name         { didSet { recompute() } }
    var sortDescending: Bool = true          { didSet { recompute() } }

    // MARK: - Selection

    var selectedID: String? {
        didSet {
            if let old = oldValue, old != selectedID { previousSelectedID = old }
        }
    }
    private(set) var previousSelectedID: String?

    // MARK: - Cached derived collections

    private(set) var loadedModels: [DiscoveredModel] = []
    private(set) var groupedRemote: [EndpointGroup] = []
    /// Populated only while `isFlattened` — the single global ranking that
    /// replaces all grouping under a metric sort. Empty otherwise.
    private(set) var flatRows: [DiscoveredModel] = []
    /// Every row the user can actually see, in visual order. Drives ↑/↓ nav, so
    /// it deliberately excludes anything inside a collapsed group.
    private(set) var flatVisible: [DiscoveredModel] = []

    // MARK: - Usage-derived stats (keyed by LMStudioModel.id)

    private(set) var speedMedians: [String: Double] = [:]
    private(set) var usageCounts: [String: Int] = [:]
    private(set) var lastUsedDates: [String: Date] = [:]
    private(set) var weeklyHistograms: [String: [Int]] = [:]

    // MARK: - Callback

    var onLaunch: ((DiscoveredModel) -> Void)?

    // MARK: - Computed helpers

    var selectedModel: DiscoveredModel? { allModels.first { $0.id == selectedID } }
    var previousModel: DiscoveredModel? {
        guard let prev = previousSelectedID else { return nil }
        return allModels.first { $0.id == prev }
    }

    var localHostname: String {
        var h = ProcessInfo.processInfo.hostName
        if h.hasSuffix(".local") { h = String(h.dropLast(6)) }
        return h
    }

    var totalVisible: Int { flatVisible.count }
    var totalAll: Int { allModels.count }
    var maxSpeedMedian: Double { speedMedians.values.max() ?? 1 }
    var maxContextLength: Int { allModels.compactMap { $0.model.maxContextLength }.max() ?? 1 }

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

    // MARK: - Inspector helpers (all keyed by DiscoveredModel.id, resolve to model.id internally)

    func speedLabel(for discoveredID: String) -> String {
        guard let item = allModels.first(where: { $0.id == discoveredID }),
              let v = speedMedians[item.model.id] else { return "—" }
        return "\(Int(v))"
    }

    func usageCount(for discoveredID: String) -> Int? {
        guard let item = allModels.first(where: { $0.id == discoveredID }) else { return nil }
        let c = usageCounts[item.model.id] ?? 0
        return c > 0 ? c : nil
    }

    func histogram(for discoveredID: String) -> [Int] {
        guard let item = allModels.first(where: { $0.id == discoveredID }) else {
            return Array(repeating: 0, count: 12)
        }
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

    // MARK: - Recompute usage stats

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

    // MARK: - Recompute filtered/sorted/grouped collections

    private func recompute() {
        let filtered = applyFilters(allModels)
        let sorted = applySort(filtered)

        // Metric sorts dissolve the grouping entirely. Ranking inside 59 vendor
        // buckets would answer "the fastest anthropic model" 59 times over
        // rather than "the fastest model", which is what sorting by Speed means.
        guard !isFlattened else {
            loadedModels = []
            groupedRemote = []
            flatRows = sorted
            flatVisible = sorted
            return
        }

        let loaded = sorted.filter { $0.model.isLoaded }
        let notLoaded = sorted.filter { !$0.model.isLoaded }

        let groups = buildGroups(notLoaded)
        loadedModels = loaded
        groupedRemote = groups
        flatRows = []
        flatVisible = loaded + visibleModels(in: groups)
    }

    /// Buckets models by endpoint, then by vendor within each endpoint.
    ///
    /// Local endpoints are hoisted above remote ones; within each half, order
    /// follows first appearance in the sorted list. Partitioned with two filters
    /// rather than a sort predicate because `sorted(by:)` is not guaranteed
    /// stable, and that would scramble the within-half ordering.
    private func buildGroups(_ items: [DiscoveredModel]) -> [EndpointGroup] {
        var order: [String] = []
        var byEndpoint: [String: [DiscoveredModel]] = [:]
        var localFlags: [String: Bool] = [:]

        for item in items {
            let key = item.server.label
            if byEndpoint[key] == nil {
                byEndpoint[key] = []
                order.append(key)
                localFlags[key] = item.server.kind.isLocal
            }
            byEndpoint[key]!.append(item)
        }

        let groups: [EndpointGroup] = order.compactMap { label in
            guard let models = byEndpoint[label], !models.isEmpty else { return nil }
            let isLocal = localFlags[label] ?? false
            // Local endpoints never sub-group. Their IDs can carry a slash too
            // (`mlx-community/Qwen2.5-7B-Instruct`), so bucketing on the prefix
            // would file the models you actually run behind a vendor group that
            // defaults to collapsed. A handful of local models is not a wall.
            return EndpointGroup(
                label: label,
                isLocal: isLocal,
                modelCount: models.count,
                vendors: isLocal ? [VendorGroup(name: nil, models: models)] : bucketByVendor(models)
            )
        }
        return groups.filter(\.isLocal) + groups.filter { !$0.isLocal }
    }

    /// Splits an endpoint's models on `providerID` (the `org/` prefix of an
    /// OpenRouter-style ID). Models without a prefix are returned first in a
    /// single unnamed bucket so local endpoints keep rendering as a flat list.
    ///
    /// Named buckets are alphabetical, following the Name sort direction — the
    /// vendor list is an index, and an index that reorders itself is unusable.
    private func bucketByVendor(_ models: [DiscoveredModel]) -> [VendorGroup] {
        var order: [String] = []
        var buckets: [String: [DiscoveredModel]] = [:]
        var unprefixed: [DiscoveredModel] = []

        for item in models {
            guard let vendor = item.model.providerID else {
                unprefixed.append(item)
                continue
            }
            if buckets[vendor] == nil {
                buckets[vendor] = []
                order.append(vendor)
            }
            buckets[vendor]!.append(item)
        }

        var groups: [VendorGroup] = []
        if !unprefixed.isEmpty { groups.append(VendorGroup(name: nil, models: unprefixed)) }
        let sortedVendors = order.sorted {
            sortDescending
                ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                : $0.localizedCaseInsensitiveCompare($1) == .orderedDescending
        }
        groups += sortedVendors.compactMap { vendor in
            buckets[vendor].map { VendorGroup(name: vendor, models: $0) }
        }
        return groups
    }

    /// Flattens the groups down to only what is on screen, for keyboard nav.
    private func visibleModels(in groups: [EndpointGroup]) -> [DiscoveredModel] {
        groups.flatMap { endpoint -> [DiscoveredModel] in
            guard !isEndpointCollapsed(endpoint.label) else { return [] }
            return endpoint.vendors.flatMap { vendor -> [DiscoveredModel] in
                guard let name = vendor.name else { return vendor.models }
                return isVendorCollapsed(endpoint.label, name) ? [] : vendor.models
            }
        }
    }

    // MARK: - Grouping / collapse policy

    /// Grouping applies only under the Name sort; every metric sort flattens.
    var isFlattened: Bool { sortKey != .name }

    /// A live query expands everything. A collapsed group swallowing matches
    /// reads as "no results", which is worse than a long list.
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func endpointKey(_ label: String) -> String { "ep|\(label)" }
    static func vendorKey(_ endpoint: String, _ vendor: String) -> String { "v|\(endpoint)|\(vendor)" }

    /// Endpoints default to expanded — folding one away is a deliberate act.
    func isEndpointCollapsed(_ label: String) -> Bool {
        guard !isSearching else { return false }
        return toggledGroups.contains(Self.endpointKey(label))
    }

    /// Vendor groups also default to expanded.
    ///
    /// Defaulting them collapsed was tried and reverted: 59 header rows with no
    /// models under them reads as a screen that failed to load, not as an index.
    /// Grouping stays purely additive — everything is visible on open, and the
    /// user folds away what they don't want, which then persists.
    func isVendorCollapsed(_ endpoint: String, _ vendor: String) -> Bool {
        guard !isSearching else { return false }
        return toggledGroups.contains(Self.vendorKey(endpoint, vendor))
    }

    private func applyFilters(_ models: [DiscoveredModel]) -> [DiscoveredModel] {
        let terms = parseQuery(searchQuery)
        return models.filter { item in
            let m = item.model
            // Chip filters
            if activeFilters.contains("free")   && !item.server.kind.isLocal && !m.isFree { return false }
            if activeFilters.contains("tools")  && !m.supportsToolUse                     { return false }
            if activeFilters.contains("vision") && !m.supportsVision                      { return false }
            if activeFilters.contains("reason") && !m.supportsThinking                    { return false }
            if activeFilters.contains("loaded") && !m.isLoaded                            { return false }
            if activeFilters.contains("favs")   && !favoriteIDs.contains(m.id)            { return false }

            // Query terms
            for term in terms {
                switch term {
                case .ctxGT(let v):
                    guard let c = m.maxContextLength, c >= v else { return false }
                case .ctxLT(let v):
                    if let c = m.maxContextLength, c > v { return false }
                case .speedGT(let v):
                    if (speedMedians[m.id] ?? 0) < v { return false }
                case .speedLT(let v):
                    let s = speedMedians[m.id] ?? 0
                    if s > 0 && s > v { return false }
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
                let as_ = speedMedians[a.model.id] ?? -1
                let bs_ = speedMedians[b.model.id] ?? -1
                result = as_ > bs_
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
            .map { t -> QueryTerm in
                if t.hasPrefix("ctx>"),   let v = parseKM(String(t.dropFirst(4))) { return .ctxGT(v) }
                if t.hasPrefix("ctx<"),   let v = parseKM(String(t.dropFirst(4))) { return .ctxLT(v) }
                if t.hasPrefix("speed>"), let v = Double(t.dropFirst(6))           { return .speedGT(v) }
                if t.hasPrefix("speed<"), let v = Double(t.dropFirst(6))           { return .speedLT(v) }
                if t.hasPrefix("used>"),  let v = Int(t.dropFirst(5))              { return .usedGT(v) }
                let caps = ["free", "tools", "vision", "reason", "loaded"]
                if caps.contains(t) { return .cap(t) }
                return .nameMatch(t)
            }
    }

    private func parseKM(_ s: String) -> Int? {
        let l = s.lowercased()
        if l.hasSuffix("k"), let n = Double(l.dropLast()) { return Int(n * 1_000) }
        if l.hasSuffix("m"), let n = Double(l.dropLast()) { return Int(n * 1_000_000) }
        return Int(l)
    }
}
