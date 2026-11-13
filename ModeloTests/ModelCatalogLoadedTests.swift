import XCTest
@testable import Modelo

final class ModelCatalogLoadedTests: XCTestCase {

    private func loaded(_ id: String) -> LMStudioModel {
        LMStudioModel(id: id, object: "model", type: "llm",
                      arch: nil, quantization: nil, state: "loaded",
                      maxContextLength: nil, publisher: nil,
                      loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
                      keepInRam: nil, isFree: false, toolUseSupported: nil)
    }

    /// Apple's always-ready model must not join the "Loaded on" section.
    @MainActor
    func test_appleIntelligenceStaysOutOfLoadedSection() {
        let apple = Server(label: "Apple Intelligence", host: "localhost", kind: .appleIntelligence)
        let studio = Server(label: "Studio", host: "studio")
        let vm = ModelCatalogViewModel()
        vm.allModels = [DiscoveredModel(server: apple, model: loaded("apple-on-device")),
                        DiscoveredModel(server: studio, model: loaded("sushi"))]

        XCTAssertEqual(vm.loadedModels.map(\.model.id), ["sushi"])
        XCTAssertEqual(vm.loadedEndpointLabels, "Studio")
        XCTAssertTrue(vm.groupedRemote.contains { $0.label == "Apple Intelligence" })
    }
}
