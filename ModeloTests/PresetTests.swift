import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class PresetTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self,
                             UsageRecord.self, Persona.self, Folder.self, Preset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    func test_preset_samplingRoundTripsThroughJSON() {
        let preset = Preset(name: "Creative")
        preset.sampling = SamplingParams(temperature: 1.1, topP: 0.95, maxTokens: 1024)
        XCTAssertEqual(preset.sampling, SamplingParams(temperature: 1.1, topP: 0.95, maxTokens: 1024))
        XCTAssertNotNil(preset.samplingJSON)
    }

    func test_preset_defaultSamplingIsEmpty() {
        XCTAssertEqual(Preset(name: "x").sampling, SamplingParams())
    }

    func test_conversation_samplingOverrideSetterWritesFields() {
        let convo = Conversation(modelID: "m", serverID: nil)
        convo.samplingOverride = SamplingParams(temperature: 0.2, maxTokens: 512)
        XCTAssertEqual(convo.temperature, 0.2)
        XCTAssertEqual(convo.maxTokens, 512)
        XCTAssertNil(convo.topP)
        XCTAssertEqual(convo.samplingOverride, SamplingParams(temperature: 0.2, maxTokens: 512))
    }

    func test_applyingPreset_overwritesConversationSamplingAndPrompt() throws {
        let ctx = try makeContext()
        let convo = Conversation(modelID: "m", serverID: nil)
        convo.temperature = 0.9            // pre-existing override
        ctx.insert(convo)
        let preset = Preset(name: "Precise")
        preset.systemPrompt = "Be terse."
        preset.sampling = SamplingParams(temperature: 0.1, topP: 0.5)
        ctx.insert(preset)

        convo.apply(preset)

        XCTAssertEqual(convo.systemPrompt, "Be terse.")
        XCTAssertEqual(convo.samplingOverride, SamplingParams(temperature: 0.1, topP: 0.5))
        XCTAssertNil(convo.maxTokens)       // preset didn't set it → cleared
    }
}
