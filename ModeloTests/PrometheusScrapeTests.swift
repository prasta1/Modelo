import XCTest
@testable import Modelo

final class PrometheusScrapeTests: XCTestCase {
    func test_parse_skipsCommentsAndParsesLabelledAndBareSamples() {
        let text = """
        # HELP vllm:num_requests_running Number of running requests.
        # TYPE vllm:num_requests_running gauge
        vllm:num_requests_running{model_name="qwen"} 3
        vllm:gpu_cache_usage_perc 0.42
        process_start_time_seconds 1.7e9
        """
        let samples = PrometheusParser.parse(text)

        XCTAssertEqual(samples.count, 3)
        let running = samples.first { $0.name == "vllm:num_requests_running" }
        XCTAssertEqual(running?.value, 3)
        XCTAssertEqual(running?.labels["model_name"], "qwen")
        XCTAssertEqual(samples.first { $0.name == "vllm:gpu_cache_usage_perc" }?.value, 0.42)
    }

    func test_parse_ignoresMalformedLines() {
        let text = """
        garbage_without_value
        nan_value foo
        ok_metric 1
        """
        let samples = PrometheusParser.parse(text)
        XCTAssertEqual(samples.map(\.name), ["ok_metric"])
    }

    func test_snapshot_extractsKnownMetricsAndNormalizesCacheToPercent() throws {
        let text = """
        vllm:num_requests_running 2
        vllm:num_requests_waiting 5
        vllm:gpu_cache_usage_perc 0.37
        """
        let snap = PrometheusSnapshot(samples: PrometheusParser.parse(text))
        XCTAssertEqual(snap.requestsRunning, 2)
        XCTAssertEqual(snap.requestsWaiting, 5)
        XCTAssertEqual(try XCTUnwrap(snap.kvCachePct), 37, accuracy: 0.001)   // 0.37 → 37%
        XCTAssertFalse(snap.isEmpty)
    }

    func test_snapshot_emptyWhenNoKnownMetrics() {
        let snap = PrometheusSnapshot(samples: PrometheusParser.parse("some_other_metric 1"))
        XCTAssertTrue(snap.isEmpty)
    }
}
