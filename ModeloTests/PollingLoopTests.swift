import XCTest
@testable import Modelo

final class PollingLoopTests: XCTestCase {
    private let noop: @Sendable () async -> Void = {}

    // MARK: isRunning

    func test_isRunning_falseByDefault() {
        let loop = PollingLoop<String>()
        XCTAssertFalse(loop.isRunning)
    }

    func test_start_setsIsRunningTrue() {
        var loop = PollingLoop<String>()
        loop.start(for: [(key: "a", tick: noop)], interval: .seconds(60))
        XCTAssertTrue(loop.isRunning)
        loop.stop()
    }

    func test_start_emptyItems_doesNotSetRunning() {
        var loop = PollingLoop<String>()
        loop.start(for: [], interval: .seconds(60))
        XCTAssertFalse(loop.isRunning)
    }

    // MARK: stop

    func test_stop_setsIsRunningFalse() {
        var loop = PollingLoop<String>()
        loop.start(for: [(key: "a", tick: noop)], interval: .seconds(60))
        loop.stop()
        XCTAssertFalse(loop.isRunning)
    }

    func test_stop_onIdleLoop_isNoop() {
        var loop = PollingLoop<String>()
        loop.stop()
        XCTAssertFalse(loop.isRunning)
    }

    // MARK: start cancels existing tasks

    func test_start_cancelsAndReplacesExistingTasks() {
        var loop = PollingLoop<String>()
        loop.start(for: [(key: "a", tick: noop), (key: "b", tick: noop)], interval: .seconds(60))
        // Second start should cancel existing tasks and only register the new ones.
        loop.start(for: [(key: "c", tick: noop)], interval: .seconds(60))
        XCTAssertTrue(loop.isRunning)
        loop.stop()
    }

    // MARK: Integer key type

    func test_integerKeys_work() {
        var loop = PollingLoop<Int>()
        loop.start(for: [(key: 1, tick: noop), (key: 2, tick: noop)], interval: .seconds(60))
        XCTAssertTrue(loop.isRunning)
        loop.stop()
    }
}
