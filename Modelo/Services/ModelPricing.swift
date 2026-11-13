import Foundation

/// What the model picker says about a model's cost, and how fresh that is. Prices only
/// ever come from the provider's own model list (OpenRouter, Nous): no price is shown
/// rather than a borrowed or out-of-date one.
enum ModelPricing {
    /// Opening the picker quietly re-fetches model lists older than this.
    static let refreshAfter: TimeInterval = 60 * 60
    /// Prices older than this are hidden until a refresh succeeds.
    static let hideAfter: TimeInterval = 24 * 60 * 60

    enum Label: Equatable {
        case local
        case price(input: Double, output: Double)
        case free(until: Date?, normalInput: Double?, normalOutput: Double?)
    }

    /// The cost label for a model row, or nil when there's nothing accurate to show
    /// (a provider that publishes no prices, or a free promo that has ended).
    static func label(for model: LMStudioModel, kind: ServerKind, now: Date) -> Label? {
        if kind.isLocal { return .local }
        if model.isFree {
            // The end date is the promo's last day, so it runs until that UTC day is over.
            if let until = model.freeUntil, now >= until.addingTimeInterval(24 * 60 * 60) { return nil }
            return .free(until: model.freeUntil,
                         normalInput: model.normalInputPricePerM,
                         normalOutput: model.normalOutputPricePerM)
        }
        guard let input = model.inputPricePerM, let output = model.outputPricePerM else { return nil }
        return .price(input: input, output: output)
    }

    /// "$0.25 in · $1.00 out" (USD per million tokens).
    static func priceText(input: Double, output: Double) -> String {
        "\(dollars(input)) in · \(dollars(output)) out"
    }

    /// Two decimals; sub-cent prices keep their digits ("$0.008") instead of "$0.00".
    private static func dollars(_ value: Double) -> String {
        if value == 0 || value >= 0.01 { return String(format: "$%.2f", value) }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        return "$" + s
    }

    /// "ends Oct 31", read in UTC so US time zones don't show the day before.
    static func endsText(_ until: Date) -> String {
        "ends " + endsFormatter.string(from: until)
    }

    /// The Models table's narrow Price cell: "$0.25 · $1.00", "FREE · Oct 31",
    /// "local", or "—" when there's nothing accurate to show.
    static func tableText(_ label: Label?) -> String {
        switch label {
        case .price(let input, let output)?: return "\(dollars(input)) · \(dollars(output))"
        case .free(let until, _, _)?:        return until.map { "FREE · " + endsFormatter.string(from: $0) } ?? "FREE"
        case .local?:                        return "local"
        case nil:                            return "—"
        }
    }

    /// The Models page's Cost row. Shows published prices while fresh; otherwise
    /// (stale, or a provider with no published price) the plain wording, never a number.
    static func costText(for model: LMStudioModel, kind: ServerKind, serverLabel: String,
                         showPrices: Bool, now: Date) -> String {
        if kind.isLocal { return "free — runs locally" }
        let plain = model.isFree ? "free" : "paid · \(serverLabel)"
        guard showPrices, let label = label(for: model, kind: kind, now: now) else { return plain }
        switch label {
        case .price(let input, let output):
            return priceText(input: input, output: output)
        case .free(let until, let normalInput, let normalOutput):
            var parts = ["free"]
            if let until { parts.append(endsText(until)) }
            if let normalInput, let normalOutput {
                parts.append("normally " + priceText(input: normalInput, output: normalOutput))
            }
            return parts.joined(separator: " · ")
        case .local:
            return "free — runs locally"
        }
    }

    private static let endsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f
    }()

    static func needsRefresh(refreshedAt: Date?, now: Date) -> Bool {
        guard let refreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) > refreshAfter
    }

    /// True when prices must be hidden. An unknown age counts as stale.
    static func isStale(refreshedAt: Date?, now: Date) -> Bool {
        guard let refreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) > hideAfter
    }

    /// "Prices updated just now" / "5m ago" / "3h ago".
    static func ageText(refreshedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(refreshedAt)))
        switch seconds {
        case ..<60:   return "Prices updated just now"
        case ..<3600: return "Prices updated \(seconds / 60)m ago"
        default:      return "Prices updated \(seconds / 3600)h ago"
        }
    }
}
