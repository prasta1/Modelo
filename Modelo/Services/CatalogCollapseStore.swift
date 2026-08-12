import Foundation

/// Persists which model-catalog groups the user has collapsed or expanded.
///
/// Stores the *delta* from each level's default rather than the absolute state:
/// a key's presence here means "the opposite of whatever that level defaults to".
/// Both levels currently default to expanded, so in practice this holds the
/// groups the user has folded away.
///
/// The indirection is deliberate — it keeps those defaults changeable without
/// stranding stale entries. That already paid off once: vendor groups shipped
/// defaulting to collapsed, and flipping them back needed no migration.
///
/// Key formats and the default policy live in `ModelCatalogViewModel`, which
/// knows the group structure. This type only persists the set.
@Observable
final class CatalogCollapseStore {
    private let key = "catalogGroupToggles"

    private(set) var toggled: Set<String> {
        didSet { UserDefaults.standard.set(Array(toggled), forKey: key) }
    }

    init() {
        toggled = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// Flips one group between collapsed and expanded.
    func toggle(_ groupKey: String) {
        if toggled.contains(groupKey) { toggled.remove(groupKey) }
        else { toggled.insert(groupKey) }
    }
}
