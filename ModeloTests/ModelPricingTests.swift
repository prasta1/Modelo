import XCTest
@testable import Modelo

final class ModelPricingTests: XCTestCase {
    private let oct31 = Date(timeIntervalSince1970: 1_793_404_800)   // 2026-10-31 00:00 UTC
    private let hour: TimeInterval = 3_600

    private func model(_ id: String = "x/y", input: Double? = nil, output: Double? = nil,
                       free: Bool = false, until: Date? = nil) -> LMStudioModel {
        var m = LMStudioModel(id: id, object: "model", type: "llm", arch: nil, quantization: nil,
                              state: nil, maxContextLength: nil, publisher: nil,
                              loadedContextLength: nil, sizeBytes: nil, sizeBytesAlt: nil,
                              keepInRam: nil, isFree: free, toolUseSupported: nil)
        m.inputPricePerM = input
        m.outputPricePerM = output
        m.freeUntil = until
        return m
    }

    func test_label_pricedCloudModel() {
        XCTAssertEqual(ModelPricing.label(for: model(input: 0.25, output: 1), kind: .openRouter, now: oct31),
                       .price(input: 0.25, output: 1))
    }

    func test_label_localModelIsNoCost() {
        XCTAssertEqual(ModelPricing.label(for: model(), kind: .lmStudio, now: oct31), .local)
    }

    /// Direct providers publish no price, and none is borrowed: no label at all.
    func test_label_unpricedCloudModelShowsNothing() {
        XCTAssertNil(ModelPricing.label(for: model(), kind: .cloudAPI, now: oct31))
    }

    func test_label_freePromoRunsThroughItsEndDay() {
        let m = model(input: 0, output: 0, free: true, until: oct31)
        XCTAssertEqual(ModelPricing.label(for: m, kind: .openRouter, now: oct31.addingTimeInterval(23 * hour)),
                       .free(until: oct31, normalInput: nil, normalOutput: nil))
        XCTAssertNil(ModelPricing.label(for: m, kind: .openRouter, now: oct31.addingTimeInterval(24 * hour)))
    }

    func test_formatting() {
        XCTAssertEqual(ModelPricing.priceText(input: 0.25, output: 1), "$0.25 in · $1.00 out")
        XCTAssertEqual(ModelPricing.priceText(input: 0.008, output: 15), "$0.008 in · $15.00 out")
        XCTAssertEqual(ModelPricing.endsText(oct31), "ends Oct 31")   // UTC day, not local
    }

    func test_freshness() {
        let now = oct31
        XCTAssertFalse(ModelPricing.needsRefresh(refreshedAt: now.addingTimeInterval(-59 * 60), now: now))
        XCTAssertTrue(ModelPricing.needsRefresh(refreshedAt: now.addingTimeInterval(-61 * 60), now: now))
        XCTAssertFalse(ModelPricing.isStale(refreshedAt: now.addingTimeInterval(-23 * hour), now: now))
        XCTAssertTrue(ModelPricing.isStale(refreshedAt: now.addingTimeInterval(-25 * hour), now: now))
        XCTAssertTrue(ModelPricing.isStale(refreshedAt: nil, now: now))
    }

    func test_ageText() {
        XCTAssertEqual(ModelPricing.ageText(refreshedAt: oct31.addingTimeInterval(-20), now: oct31), "Prices updated just now")
        XCTAssertEqual(ModelPricing.ageText(refreshedAt: oct31.addingTimeInterval(-5 * 60), now: oct31), "Prices updated 5m ago")
        XCTAssertEqual(ModelPricing.ageText(refreshedAt: oct31.addingTimeInterval(-3 * hour), now: oct31), "Prices updated 3h ago")
    }
}
