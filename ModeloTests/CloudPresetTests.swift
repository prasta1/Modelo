import XCTest
@testable import Modelo

final class CloudPresetTests: XCTestCase {
    func test_all_haveNamesAndHTTPSBaseURLs() throws {
        XCTAssertEqual(CloudPreset.all.count, 6)
        for p in CloudPreset.all {
            XCTAssertFalse(p.name.isEmpty)
            let url = try XCTUnwrap(URL(string: p.baseURL), p.name)
            XCTAssertEqual(url.scheme, "https", p.name)
            XCTAssertNotNil(url.host(), p.name)
        }
    }

    func test_ids_areUnique() {
        XCTAssertEqual(Set(CloudPreset.all.map(\.id)).count, CloudPreset.all.count)
    }
}
