import Foundation

/// Persists a set of favorited model IDs to UserDefaults.
///
/// A model is identified by its `LMStudioModel.id` string (e.g.
/// "mlx-community/Qwen2.5-7B-Instruct"). The same model ID is treated as
/// favorited across all servers that host it.
@Observable
final class FavoritesStore {
    private let key = "favoriteModelIDs"

    private(set) var favoriteIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(favoriteIDs), forKey: key) }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        favoriteIDs = Set(stored)
    }

    func toggle(_ modelID: String) {
        if favoriteIDs.contains(modelID) { favoriteIDs.remove(modelID) }
        else { favoriteIDs.insert(modelID) }
    }

    func isFavorite(_ modelID: String) -> Bool {
        favoriteIDs.contains(modelID)
    }
}
