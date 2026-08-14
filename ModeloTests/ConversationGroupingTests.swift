import Testing
import Foundation
@testable import Modelo

struct ConversationGroupingTests {
    /// Fixed reference point: noon on Friday 14 Aug 2026. Mid-week and mid-month
    /// on purpose — the bucketing uses `Calendar.current`, whose `firstWeekday`
    /// varies by locale, and a mid-week anchor lands the same way under all of
    /// them. Noon keeps the fixtures clear of midnight boundaries.
    private func referenceNow() -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!
    }

    private func convo(title: String = "c", model: String = "m",
                       server: UUID? = nil, daysAgo: Int, now: Date) -> Conversation {
        let c = Conversation(modelID: model, serverID: server)
        c.title = title
        c.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return c
    }

    @Test func dateBuckets_splitIntoTodayThisWeekAndThisMonth() {
        let now = referenceNow()
        let convos = [
            convo(daysAgo: 0, now: now),
            convo(daysAgo: 1, now: now),
            convo(daysAgo: 10, now: now),
        ]
        let buckets = ConversationGrouping.dateBuckets(convos, now: now)
        #expect(buckets.map(\.title) == ["Today", "This Week", "This Month"])
    }

    @Test func dateBuckets_coverAllRangesInOrder() {
        let now = referenceNow()
        let convos = [
            convo(daysAgo: 0, now: now),   // today
            convo(daysAgo: 1, now: now),   // earlier this week
            convo(daysAgo: 10, now: now),  // earlier this month
            convo(daysAgo: 90, now: now),  // older
        ]
        let buckets = ConversationGrouping.dateBuckets(convos, now: now)
        #expect(buckets.map(\.title) == ["Today", "This Week", "This Month", "Older"])
    }

    @Test func dateBuckets_omitEmptyBuckets() {
        let now = referenceNow()
        let buckets = ConversationGrouping.dateBuckets([convo(daysAgo: 0, now: now)], now: now)
        #expect(buckets.count == 1)
        #expect(buckets.first?.title == "Today")
    }
}
