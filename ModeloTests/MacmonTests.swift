import XCTest
@testable import Modelo

final class MacmonTests: XCTestCase {
    /// A representative `macmon pipe` line maps into the shared GPUSnapshot.
    func test_parse_mapsSampleToSnapshot() throws {
        let line = #"""
        {"gpu_power":3.5,"gpu_usage":[338,0.42],"temp":{"cpu_temp_avg":43.0,"gpu_temp_avg":47.5},"memory":{"ram_total":51539607552,"ram_usage":36139515904,"swap_total":0,"swap_usage":0}}
        """#
        let snap = try XCTUnwrap(Macmon.parse(line))
        XCTAssertEqual(snap.utilPct, 42, accuracy: 0.001)          // 0.42 → 42%
        XCTAssertEqual(snap.powerW, 3.5, accuracy: 0.001)
        XCTAssertEqual(snap.tempC, 47.5, accuracy: 0.001)
        XCTAssertEqual(snap.vramTotalGB, 51.539607552, accuracy: 0.001)
        XCTAssertEqual(snap.vramUsedGB, 36.139515904, accuracy: 0.001)
        XCTAssertEqual(snap.powerLimitW, 0)
        XCTAssertTrue(snap.devices.isEmpty)
    }

    func test_parse_rejectsNonSampleLines() {
        XCTAssertNil(Macmon.parse(""))
        XCTAssertNil(Macmon.parse("not json"))
    }

    func test_parse_toleratesMissingFields() throws {
        // A sample with no GPU usage array still decodes (util defaults to 0).
        let snap = try XCTUnwrap(Macmon.parse(#"{"gpu_power":1.0}"#))
        XCTAssertEqual(snap.utilPct, 0)
        XCTAssertEqual(snap.powerW, 1.0, accuracy: 0.001)
    }
}
