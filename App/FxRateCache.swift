import Foundation
import KeepoCore

/// Same shape as `CurrencyCache`: a timeout-capped live fetch that falls
/// back to whatever was last cached, so an offline net-worth read has a
/// rate to convert pending amounts with instead of silently dropping
/// out-of-base-currency accounts from the overlay.
@MainActor
public enum FxRateCache {
    private static let key = "fx_rates_latest"

    public static func fetchLatestRates(session: SessionStore) async -> [String: Decimal] {
        if let fetched = try? await withTimeout(seconds: 3, operation: {
            try await FxRateRepository.fetchLatestRates(client: session.client)
        }) {
            if let data = try? JSONEncoder().encode(fetched) {
                session.payloadCache.save(key: key, data: data)
            }
            return fetched
        }
        guard let (data, _) = session.payloadCache.load(key: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Decimal].self, from: data)) ?? [:]
    }
}
