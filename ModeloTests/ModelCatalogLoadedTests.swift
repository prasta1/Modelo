import XCTest
@testable import Modelo

final class ModelCatalogLoadedTests: XCTestCase {

    private func model(_ id: String, state: String) -> LMStudioModel {
        LMStudioModel(id: id, object: "model", type: "llm",
                      arch: nil, quantization: nil, state: state,
                      maxContextLength: nil, publisher: nil,
                      loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
                      keepInRam: nil, isFree: false, toolUseSupported: nil)
    }
    private func loaded(_ id: String) -> LMStudioModel { model(id, state: "loaded") }
    private func notLoaded(_ id: String) -> LMStudioModel { model(id, state: "not-loaded") }

    /// Apple's always-ready model must not get a loaded tile.
    @MainActor
    func test_appleIntelligenceStaysOutOfLoadedSection() {
        let apple = Server(label: "Apple Intelligence", host: "localhost", kind: .appleIntelligence)
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: apple, model: loaded("apple-on-device")),
                        DiscoveredModel(server: studio, model: loaded("sushi"))]

        XCTAssertEqual(vm.loadedModels.map(\.model.id), ["sushi"])
        XCTAssertTrue(vm.groupedRemote.contains { $0.label == "Apple Intelligence" })
    }

    /// Tiles are a status strip: search narrows the table, never the tiles.
    @MainActor
    func test_loadedModelsIgnoreSearchAndFilters() {
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: studio, model: loaded("sushi")),
                        DiscoveredModel(server: studio, model: notLoaded("qwen"))]
        vm.searchQuery = "qwen"

        XCTAssertEqual(vm.loadedModels.map(\.model.id), ["sushi"])
        XCTAssertFalse(vm.flatVisible.contains { $0.model.id == "sushi" })
    }

    /// A metric sort ranks every model, loaded ones included, and keeps the tiles.
    @MainActor
    func test_loadedModelsSurviveFlattenedSort() {
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: studio, model: loaded("sushi")),
                        DiscoveredModel(server: studio, model: notLoaded("qwen"))]
        vm.sortKey = .speed

        XCTAssertEqual(vm.loadedModels.map(\.model.id), ["sushi"])
        XCTAssertTrue(vm.flatVisible.contains { $0.model.id == "sushi" })
    }

    @MainActor
    func test_sameModelOnTwoEndpointsGetsTwoTiles() {
        let macbook = Server(label: "MacBook", host: "macbook")
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: studio, model: loaded("sushi")),
                        DiscoveredModel(server: macbook, model: loaded("sushi"))]

        XCTAssertEqual(vm.loadedModels.map(\.server.label), ["MacBook", "Studio"])
    }

    /// "loaded" is no longer a filter term: typing it must not report loaded
    /// models as matches the table can't show.
    @MainActor
    func test_loadedSearchTermIsPlainNameMatch() {
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: studio, model: loaded("sushi")),
                        DiscoveredModel(server: studio, model: notLoaded("qwen"))]
        vm.searchQuery = "loaded"

        XCTAssertEqual(vm.filteredCount, 0)
    }

    /// ↑ from a tile selection starts at the top of the table, not its last row.
    @MainActor
    func test_selectPreviousFromTileGoesToFirstRow() {
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        let tile = DiscoveredModel(server: studio, model: loaded("sushi"))
        vm.allModels = [tile,
                        DiscoveredModel(server: studio, model: notLoaded("alpha")),
                        DiscoveredModel(server: studio, model: notLoaded("zeta"))]
        vm.selectedID = tile.id

        vm.selectPrevious()

        XCTAssertEqual(vm.selectedID, vm.flatVisible.first?.id)
    }

    /// The "N models" count matches the table: in name sort loaded models are
    /// tiles, not rows; a metric sort ranks them as rows again.
    @MainActor
    func test_modelCountExcludesTilesOnlyInGroupedMode() {
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: studio, model: loaded("sushi")),
                        DiscoveredModel(server: studio, model: notLoaded("qwen"))]

        XCTAssertEqual(vm.totalVisible, 1)
        vm.sortKey = .speed
        XCTAssertEqual(vm.totalVisible, 2)
    }
}
