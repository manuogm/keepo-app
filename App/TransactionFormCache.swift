import KeepoCore
import Foundation

/// The on-device fallback `TransactionFormView.load()` reaches for when the
/// live fetch fails — an offline create otherwise has no way to populate
/// its own pickers, even though the write itself (via the outbox) works
/// offline. Extracted to its own file purely to keep `TransactionFormView`
/// under the project's file-length lint threshold.
@MainActor
enum TransactionFormCache {
    static func accounts(session: SessionStore) -> [PublicSchema.AccountsWithBalancesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "accounts_with_balances") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.AccountsWithBalancesSelect].self, from: data)) ?? []
    }

    static func categories(session: SessionStore) -> [PublicSchema.CategoriesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "categories") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.CategoriesSelect].self, from: data)) ?? []
    }
}
