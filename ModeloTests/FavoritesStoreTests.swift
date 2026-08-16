import XCTest
@testable import Modelo

final class FavoritesStoreTests: XCTestCase {
    private let udKey = "favoriteModelIDs"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    // MARK: toggle

    func test_toggle_addsMissingModel() {
        let store = FavoritesStore()
        store.toggle("mlx-community/Qwen2.5-7B")
        XCTAssertTrue(store.isFavorite("mlx-community/Qwen2.5-7B"))
    }

    func test_toggle_removesAlreadyFavoritedModel() {
        let store = FavoritesStore()
        store.toggle("model-a")
        store.toggle("model-a")
        XCTAssertFalse(store.isFavorite("model-a"))
    }

    func test_toggle_multipleModelsAreIndependent() {
        let store = FavoritesStore()
        store.toggle("model-a")
        store.toggle("model-b")
        XCTAssertTrue(store.isFavorite("model-a"))
        XCTAssertTrue(store.isFavorite("model-b"))
        store.toggle("model-a")
        XCTAssertFalse(store.isFavorite("model-a"))
        XCTAssertTrue(store.isFavorite("model-b"))
    }

    // MARK: isFavorite

    func test_isFavorite_falseForUnknownModel() {
        let store = FavoritesStore()
        XCTAssertFalse(store.isFavorite("nonexistent"))
    }

    // MARK: persistence

    func test_persistsAcrossInstances() {
        let store1 = FavoritesStore()
        store1.toggle("persistent-model")

        let store2 = FavoritesStore()
        XCTAssertTrue(store2.isFavorite("persistent-model"))
    }

    func test_toggleOffPersistsAcrossInstances() {
        let store1 = FavoritesStore()
        store1.toggle("model-x")
        store1.toggle("model-x")

        let store2 = FavoritesStore()
        XCTAssertFalse(store2.isFavorite("model-x"))
    }
}
