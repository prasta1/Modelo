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

/// All filter/sort/selection state for ModelCatalogView. Derived collections
/// are cached in didSet so ForEach never sorts/filters inline.
@Observable @MainActor
final class ModelCatalogViewModel {

    // MARK: - Inputs (set by view on appear/change)

    var allModels: [DiscoveredModel] = []    { didSet { recompute() } }
    var usageRecords: [UsageRecord] = []     { didSet { recomputeUsage(); recompute() } }
    var favoriteIDs: Set<String> = []        { didSet { recompute() } }

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
    private(set) var groupedRemote: [(name: String, models: [DiscoveredModel])] = []
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
        groupedRemote = groupOrder.compactMap { name in
            guard let models = groupMap[name], !models.isEmpty else { return nil }
            return (name: name, models: models)
        }
        flatVisible = loaded + notLoaded
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
