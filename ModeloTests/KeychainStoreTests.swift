import XCTest
@testable import Modelo

final class KeychainStoreTests: XCTestCase {
    // Use a unique service per run so tests never collide with real app keys.
    private func store() -> KeychainStore {
        KeychainStore(service: "com.peregrine.modelo.tests.\(UUID().uuidString)")
    }

    func test_setThenGet_roundTrips() {
        let s = store()
        s.set("fc-secret", account: "firecrawl")
        XCTAssertEqual(s.get(account: "firecrawl"), "fc-secret")
    }

    func test_get_missing_returnsNil() {
        XCTAssertNil(store().get(account: "nope"))
    }

    func test_set_overwrites() {
        let s = store()
        s.set("one", account: "k")
        s.set("two", account: "k")
        XCTAssertEqual(s.get(account: "k"), "two")
    }

    func test_setNil_deletes() {
        let s = store()
        s.set("x", account: "k")
        s.set(nil, account: "k")
        XCTAssertNil(s.get(account: "k"))
    }
}
