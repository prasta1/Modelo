import XCTest
@testable import Modelo

final class CatalogCollapseStoreTests: XCTestCase {
    private let udKey = "catalogGroupToggles"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    // MARK: toggle

    func test_toggle_addsMissingKey() {
        let store = CatalogCollapseStore()
        store.toggle("vendor/qwen")
        XCTAssertTrue(store.toggled.contains("vendor/qwen"))
    }

    func test_toggle_removesExistingKey() {
        let store = CatalogCollapseStore()
        store.toggle("vendor/qwen")
        store.toggle("vendor/qwen")
        XCTAssertFalse(store.toggled.contains("vendor/qwen"))
    }

    func test_toggle_multipleKeysAreIndependent() {
        let store = CatalogCollapseStore()
        store.toggle("vendor/a")
        store.toggle("vendor/b")
        XCTAssertTrue(store.toggled.contains("vendor/a"))
        XCTAssertTrue(store.toggled.contains("vendor/b"))
        store.toggle("vendor/a")
        XCTAssertFalse(store.toggled.contains("vendor/a"))
        XCTAssertTrue(store.toggled.contains("vendor/b"))
    }

    func test_initiallyEmpty() {
        let store = CatalogCollapseStore()
        XCTAssertTrue(store.toggled.isEmpty)
    }

    // MARK: persistence

    func test_persistsAcrossInstances() {
        let store1 = CatalogCollapseStore()
        store1.toggle("group/mlx")

        let store2 = CatalogCollapseStore()
        XCTAssertTrue(store2.toggled.contains("group/mlx"))
    }
}
