import Foundation
import KeepoCore

/// `CurrencyRepository.fetchAll` is near-static reference data, fetched
/// unguarded (`try?`, no timeout) from six different screens
/// (AccountFormView, TransactionsListView, PreferencesView, HomeView,
/// OnboardingView, NeedsReviewView) — every one of them silently waited
/// out the default ~60s URLSession timeout while offline before falling
/// back to an empty list, which is what made account/transaction forms
/// feel hung rather than merely offline. One timeout-capped, cache-backed
/// fetch here, reused everywhere, fixes all six at once.
@MainActor
public enum CurrencyCache {
    private static let key = "currencies"

    public static func fetchAll(session: SessionStore) async -> [PublicSchema.CurrenciesSelect] {
        let fetched = try? await withTimeout(seconds: 3, operation: {
            try await CurrencyRepository.fetchAll(client: session.client)
        })
        if let fetched {
            if let data = try? JSONEncoder().encode(fetched) {
                session.payloadCache.save(key: key, data: data)
            }
            return fetched
        }
        guard let (data, _) = session.payloadCache.load(key: key) else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.CurrenciesSelect].self, from: data)) ?? []
    }
}
