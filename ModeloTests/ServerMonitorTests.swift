import Testing
import Foundation
@testable import Modelo

// MARK: - Fake provider for ServerMonitor tests

private final class FakeMonitorProvider: ChatProvider {
    var modelsJSON: String = "{\"data\":[]}"
    var shouldThrow = false

    func fetchModels(endpoint: Endpoint) async throws -> [LMStudioModel] {
        if shouldThrow { throw ClientError.unreachable }
        let data = modelsJSON.data(using: .utf8)!
        return (try? JSONDecoder().decode(ModelsResponse.self, from: data).data) ?? []
    }

    func streamChat(endpoint: Endpoint, modelID: String, messages: [Message],
                    systemPrompt: String, sampling: SamplingParams,
                    tools: [ToolSpec]?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Tests

@Suite("ServerMonitor")
@MainActor
struct ServerMonitorTests {

    @Test func snapshotNilBeforePoll() {
        let monitor = ServerMonitor(client: FakeMonitorProvider())
        let server = Server(label: "Studio", host: "studio")
        #expect(monitor.snapshot(for: server) == nil)
    }

    @Test func pollSetsSnapshotForLoadedModel() async {
        let provider = FakeMonitorProvider()
        provider.modelsJSON = """
        {"data":[{"id":"qwen3-30b","state":"loaded","type":"llm"}]}
        """
        let monitor = ServerMonitor(client: provider)
        let server = Server(label: "Studio", host: "studio")

        await monitor.poll(server)

        let snap = monitor.snapshot(for: server)
        #expect(snap != nil)
        #expect(snap?.models.first?.id == "qwen3-30b")
    }

    @Test func pollPrefersLoadedOverFirst() async {
        let provider = FakeMonitorProvider()
        provider.modelsJSON = """
        {"data":[
          {"id":"unloaded-model","state":"not-loaded","type":"llm"},
          {"id":"loaded-model","state":"loaded","type":"llm"}
        ]}
        """
        let monitor = ServerMonitor(client: provider)
        let server = Server(label: "Studio", host: "studio")

        await monitor.poll(server)

        #expect(monitor.snapshot(for: server)?.models.first?.id == "loaded-model")
    }

    @Test func pollOnNetworkErrorLeavesSnapshotUnchanged() async {
        let provider = FakeMonitorProvider()
        let monitor = ServerMonitor(client: provider)
        let server = Server(label: "Studio", host: "studio")

        // First poll succeeds
        provider.modelsJSON = #"{"data":[{"id":"model-a","state":"loaded","type":"llm"}]}"#
        await monitor.poll(server)
        #expect(monitor.snapshot(for: server)?.models.first?.id == "model-a")

        // Second poll fails — snapshot should stay
        provider.shouldThrow = true
        await monitor.poll(server)
        #expect(monitor.snapshot(for: server)?.models.first?.id == "model-a")
    }

    @Test func pollCapturesAllLoadedModels() async {
        let provider = FakeMonitorProvider()
        provider.modelsJSON = """
        {"data":[
          {"id":"model-a","state":"loaded","type":"llm"},
          {"id":"model-b","state":"loaded","type":"llm"},
          {"id":"model-c","state":"not-loaded","type":"llm"}
        ]}
        """
        let monitor = ServerMonitor(client: provider)
        let server = Server(label: "Studio", host: "studio")

        await monitor.poll(server)

        let ids = monitor.snapshot(for: server)?.models.map(\.id)
        #expect(ids == ["model-a", "model-b"])
    }

    @Test func pollFallsBackToFirstModelWhenNoneLoaded() async {
        let provider = FakeMonitorProvider()
        provider.modelsJSON = """
        {"data":[
          {"id":"first-model","type":"llm"},
          {"id":"second-model","type":"llm"}
        ]}
        """
        let monitor = ServerMonitor(client: provider)
        let server = Server(label: "Studio", host: "studio")

        await monitor.poll(server)

        #expect(monitor.snapshot(for: server)?.models.first?.id == "first-model")
    }
}
