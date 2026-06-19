import Testing
import Foundation
@testable import Modelo

struct ConversationGroupingTests {
    /// Noon today, to keep date bucketing clear of midnight boundaries.
    private func noonToday() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func convo(title: String = "c", model: String = "m",
                       server: UUID? = nil, daysAgo: Int, now: Date) -> Conversation {
        let c = Conversation(modelID: model, serverID: server)
        c.title = title
        c.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return c
    }

    @Test func dateBuckets_splitIntoTodayYesterdayAndOlder() {
        let now = noonToday()
        let convos = [
            convo(daysAgo: 0, now: now),
            convo(daysAgo: 1, now: now),
            convo(daysAgo: 10, now: now),
        ]
        let buckets = ConversationGrouping.dateBuckets(convos, now: now)
        #expect(buckets.map(\.title) == ["Today", "Yesterday", "Previous 30 Days"])
    }

    @Test func dateBuckets_coverAllRangesInOrder() {
        let now = noonToday()
        let convos = [
            convo(daysAgo: 0, now: now),   // today
            convo(daysAgo: 1, now: now),   // yesterday
            convo(daysAgo: 4, now: now),   // previous 7 days
            convo(daysAgo: 20, now: now),  // previous 30 days
            convo(daysAgo: 90, now: now),  // older
        ]
        let buckets = ConversationGrouping.dateBuckets(convos, now: now)
        #expect(buckets.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"])
    }

    @Test func dateBuckets_omitEmptyBuckets() {
        let now = noonToday()
        let buckets = ConversationGrouping.dateBuckets([convo(daysAgo: 0, now: now)], now: now)
        #expect(buckets.count == 1)
        #expect(buckets.first?.title == "Today")
    }
}
