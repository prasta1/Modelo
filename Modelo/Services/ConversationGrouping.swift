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
        case today, yesterday, previous7Days, previous30Days, older

        var title: String {
            switch self {
            case .today:          "Today"
            case .yesterday:      "Yesterday"
            case .previous7Days:  "Previous 7 Days"
            case .previous30Days: "Previous 30 Days"
            case .older:          "Older"
            }
        }
    }

    /// Groups `conversations` (already sorted newest-first) into date buckets.
    /// `now` is injected so the bucketing is testable.
    static func dateBuckets(_ conversations: [Conversation], now: Date) -> [ConversationBucket] {
        let cal = Calendar.current
        let sevenDaysAgo  = cal.date(byAdding: .day, value: -7,  to: now)!
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now)!

        var byBucket: [DateBucket: [Conversation]] = [:]
        for convo in conversations {
            let d = convo.createdAt
            let bucket: DateBucket
            if cal.isDateInToday(d)          { bucket = .today }
            else if cal.isDateInYesterday(d) { bucket = .yesterday }
            else if d >= sevenDaysAgo        { bucket = .previous7Days }
            else if d >= thirtyDaysAgo       { bucket = .previous30Days }
            else                             { bucket = .older }
            byBucket[bucket, default: []].append(convo)
        }

        return DateBucket.allCases.compactMap { b in
            guard let convos = byBucket[b], !convos.isEmpty else { return nil }
            return ConversationBucket(id: "date:" + b.rawValue, title: b.title, conversations: convos)
        }
    }
}
