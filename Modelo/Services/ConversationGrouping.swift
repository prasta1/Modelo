import Foundation

/// A titled bucket of conversations for the sidebar list.
struct ConversationBucket: Identifiable {
    let id: String
    let title: String
    let conversations: [Conversation]
}

/// Pure date-bucketing of conversations for the sidebar. Kept out of the view so
/// the bucketing reads clearly and can be unit-tested. Folder and pinned grouping
/// live in the view since they depend on SwiftData relationships.
enum ConversationGrouping {
    private enum DateBucket: String, CaseIterable {
        case today, thisWeek, thisMonth, older

        var title: String {
            switch self {
            case .today:     "Today"
            case .thisWeek:  "This Week"
            case .thisMonth: "This Month"
            case .older:     "Older"
            }
        }
    }

    /// Groups `conversations` (already sorted newest-first) into date buckets.
    /// `now` is injected so the bucketing is testable.
    static func dateBuckets(_ conversations: [Conversation], now: Date) -> [ConversationBucket] {
        let cal = Calendar.current

        var byBucket: [DateBucket: [Conversation]] = [:]
        for convo in conversations {
            let d = convo.createdAt
            let bucket: DateBucket
            if cal.isDate(d, inSameDayAs: now) {
                bucket = .today
            } else if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) {
                bucket = .thisWeek
            } else if cal.isDate(d, equalTo: now, toGranularity: .month) {
                bucket = .thisMonth
            } else {
                bucket = .older
            }
            byBucket[bucket, default: []].append(convo)
        }

        return DateBucket.allCases.compactMap { b in
            guard let convos = byBucket[b], !convos.isEmpty else { return nil }
            return ConversationBucket(id: "date:" + b.rawValue, title: b.title, conversations: convos)
        }
    }
}
