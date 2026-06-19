import XCTest
@testable import Modelo

@MainActor
final class ReachabilityMonitorTests: XCTestCase {
    func test_pollInterval_lmStudio_is10sOnline_30sOtherwise() {
        let monitor = ReachabilityMonitor(registry: ServerRegistry(), probe: { _ in true })
        XCTAssertEqual(monitor.pollInterval(for: .online, kind: .lmStudio), .seconds(10))
        XCTAssertEqual(monitor.pollInterval(for: .offline, kind: .lmStudio), .seconds(30))
        XCTAssertEqual(monitor.pollInterval(for: .unknown, kind: .lmStudio), .seconds(30))
    }

    func test_pollInterval_cloudAPI_isFixed30s_regardlessOfStatus() {
        let monitor = ReachabilityMonitor(registry: ServerRegistry(), probe: { _ in true })
        XCTAssertEqual(monitor.pollInterval(for: .online, kind: .cloudAPI), .seconds(30))
        XCTAssertEqual(monitor.pollInterval(for: .offline, kind: .cloudAPI), .seconds(30))
    }

    func test_checkOnce_setsOnlineWhenProbeSucceeds() async {
        let registry = ServerRegistry()
        let monitor = ReachabilityMonitor(registry: registry, probe: { _ in true })
        let server = Server(label: "Studio", host: "studio")
        await monitor.checkOnce(server)
        XCTAssertEqual(registry.status(for: server), .online)
    }

    func test_checkOnce_setsOfflineWhenProbeFails() async {
        let registry = ServerRegistry()
        let monitor = ReachabilityMonitor(registry: registry, probe: { _ in false })
        let server = Server(label: "MacBook", host: "macbook")
        await monitor.checkOnce(server)
        XCTAssertEqual(registry.status(for: server), .offline)
    }
}
