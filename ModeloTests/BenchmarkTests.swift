import XCTest
@testable import Modelo

@MainActor
final class BenchmarkTests: XCTestCase {
    func test_percentile_interpolatesAndHandlesEdges() {
        XCTAssertEqual(Percentile.value([], 0.5), 0)
        XCTAssertEqual(Percentile.value([42], 0.95), 42)
        XCTAssertEqual(Percentile.value([0, 10], 0.5), 5, accuracy: 0.0001)
        let xs = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(Percentile.value(xs, 0.0), 1)
        XCTAssertEqual(Percentile.value(xs, 1.0), 10)
        XCTAssertEqual(Percentile.value(xs, 0.5), 5.5, accuracy: 0.0001)
    }

    func test_report_aggregatesSuccessAndPercentiles() {
        let results = [
            BenchmarkResult(success: true, ttft: 0.1, tokensPerSec: 100),
            BenchmarkResult(success: true, ttft: 0.3, tokensPerSec: 50),
            BenchmarkResult(success: false, ttft: 0, tokensPerSec: 0),
        ]
        let r = BenchmarkReport(results: results, wallSeconds: 2.0)
        XCTAssertEqual(r.total, 3)
        XCTAssertEqual(r.succeeded, 2)
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(r.ttftP50, 0.2, accuracy: 0.0001)   // midpoint of the 2 successes
        XCTAssertEqual(r.tpsP50, 75, accuracy: 0.0001)
    }

    func test_runner_completesAllRequestsAndReports() async {
        let provider = FakeProvider(events: [.delta("hi"), .usage(promptTokens: 1, completionTokens: 2)])
        let runner = BenchmarkRunner(client: provider)
        let endpoint = Endpoint(baseURL: "http://x", kind: .lmStudio, apiKey: nil)

        runner.run(endpoint: endpoint, modelID: "m", prompt: "go", requests: 6, concurrency: 3)
        // Drain until the run finishes (FakeProvider returns immediately).
        while runner.isRunning { await Task.yield() }

        let report = try! XCTUnwrap(runner.report)
        XCTAssertEqual(report.total, 6)
        XCTAssertEqual(report.succeeded, 6)
        XCTAssertEqual(report.failed, 0)
    }
}
