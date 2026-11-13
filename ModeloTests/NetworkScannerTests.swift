import XCTest
@testable import Modelo

@MainActor
final class NetworkScannerTests: XCTestCase {
    func test_scanningLabel_oneSubnet() {
        XCTAssertEqual(NetworkScanner.scanningLabel(subnets: ["192.168.1"], portCount: 5),
                       "Scanning localhost + 192.168.1.x on 5 ports…")
    }

    func test_scanningLabel_twoSubnets() {
        XCTAssertEqual(NetworkScanner.scanningLabel(subnets: ["192.168.1", "10.0.0"], portCount: 5),
                       "Scanning localhost + 192.168.1.x, 10.0.0.x on 5 ports…")
    }

    /// Wi-Fi off / no active interface: only localhost is scanned.
    func test_scanningLabel_noSubnets() {
        XCTAssertEqual(NetworkScanner.scanningLabel(subnets: [], portCount: 5),
                       "Scanning localhost on 5 ports…")
    }

    func test_summary_none() {
        XCTAssertEqual(NetworkScanner.summary(foundCount: 0, alreadyAdded: 0, subnets: ["192.168.1"]),
                       "Scan complete — no servers found on localhost or 192.168.1.x.")
    }

    func test_summary_none_noSubnets() {
        XCTAssertEqual(NetworkScanner.summary(foundCount: 0, alreadyAdded: 0, subnets: []),
                       "Scan complete — no servers found on localhost.")
    }

    func test_summary_oneAllAdded() {
        XCTAssertEqual(NetworkScanner.summary(foundCount: 1, alreadyAdded: 1, subnets: ["192.168.1"]),
                       "Scan complete — 1 server found (1 already added).")
    }

    func test_summary_severalNoneAdded() {
        XCTAssertEqual(NetworkScanner.summary(foundCount: 3, alreadyAdded: 0, subnets: ["192.168.1"]),
                       "Scan complete — 3 servers found.")
    }
}
