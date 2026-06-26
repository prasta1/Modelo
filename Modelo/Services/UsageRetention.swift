import Foundation
import SwiftData

/// Prunes old `UsageRecord`s per a user-set retention window (§3.4). Modelo otherwise
/// keeps usage forever. Run on launch and when Reports opens.
enum UsageRetention {
    /// `@AppStorage`/`UserDefaults` key. 0 = keep forever.
    static let key = "usageRetentionDays"

    /// Deletes records older than `retentionDays`. No-op when `retentionDays <= 0`.
    /// `now` is injected for testability.
    static func prune(in context: ModelContext, retentionDays: Int, now: Date = Date()) {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
        else { return }
        let descriptor = FetchDescriptor<UsageRecord>(predicate: #Predicate { $0.timestamp < cutoff })
        guard let old = try? context.fetch(descriptor), !old.isEmpty else { return }
        for record in old { context.delete(record) }
        do {
            try context.save()
        } catch {
            // Don't leave pending deletes dangling in the context for an unrelated save
            // to commit later — roll back to a clean state on failure.
            context.rollback()
        }
    }
}
