import Foundation
import SwiftData

/// The read-through half of Phase 11's design: writes the *server-computed,
/// already-decoded* rows from every successful fetch, keyed by query key,
/// and replays them cold-start or offline with the timestamp they were
/// fetched at. Never re-computes anything — it only ever re-encodes and
/// re-decodes rows Postgres already produced (money rule 3), which is the
/// whole reason this exists instead of a local-first mirror.
@MainActor
public final class PayloadCache {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func save(key: String, data: Data) {
        let now = Date()
        if let existing = existing(for: key) {
            existing.payloadJSON = data
            existing.fetchedAt = now
        } else {
            context.insert(CachedPayload(key: key, payloadJSON: data, fetchedAt: now))
        }
        try? context.save()
    }

    public func load(key: String) -> (data: Data, fetchedAt: Date)? {
        guard let row = existing(for: key) else { return nil }
        return (row.payloadJSON, row.fetchedAt)
    }

    private func existing(for key: String) -> CachedPayload? {
        var descriptor = FetchDescriptor<CachedPayload>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
