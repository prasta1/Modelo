import XCTest
import SwiftData
@testable import Modelo

@MainActor
final class UsageRetentionTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Server.self, Conversation.self, Message.self,
                             UsageRecord.self, Persona.self, Folder.self, Preset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func record(daysAgo: Int, now: Date) -> UsageRecord {
        let r = UsageRecord(modelID: "m", serverLabel: "s", promptTokens: 1,
                            completionTokens: 1, tokensPerSecond: 1, ttftMillis: 1)
        r.timestamp = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return r
    }

    func test_prune_deletesOnlyRecordsOlderThanWindow() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(record(daysAgo: 40, now: now))   // pruned
        ctx.insert(record(daysAgo: 31, now: now))   // pruned
        ctx.insert(record(daysAgo: 30, now: now))   // kept — exactly at the cutoff (timestamp == cutoff, not < )
        ctx.insert(record(daysAgo: 10, now: now))   // kept
        ctx.insert(record(daysAgo: 0,  now: now))   // kept
        try ctx.save()

        UsageRetention.prune(in: ctx, retentionDays: 30, now: now)

        let remaining = try ctx.fetch(FetchDescriptor<UsageRecord>())
        XCTAssertEqual(remaining.count, 3)
    }

    func test_prune_zeroDays_keepsEverything() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        ctx.insert(record(daysAgo: 999, now: now))
        try ctx.save()

        UsageRetention.prune(in: ctx, retentionDays: 0, now: now)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<UsageRecord>()).count, 1)
    }
}
