import Foundation
import KeepoCore

/// Per-account read-through fallback for the edit sheet — deliberately NOT
/// the shared "accounts_with_balances" cache `AccountsListView` already
/// populates: that view exposes the computed running `balance`, never the
/// stored `opening_balance` the edit form actually needs to prefill (see
/// AccountFormView.load). Reusing it here would silently substitute a
/// running balance into the opening-balance field — exactly the kind of
/// wrong-number-shown-as-truth this whole offline pass exists to avoid.
/// Keyed per-account so it only ever holds the one row currently being
/// edited, refreshed on every successful fetch.
@MainActor
enum AccountFormCache {
    static func save(_ account: PublicSchema.AccountsSelect, session: SessionStore) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        session.payloadCache.save(key: "account:\(account.id)", data: data)
    }

    static func load(id: UUID, session: SessionStore) -> PublicSchema.AccountsSelect? {
        guard let (data, _) = session.payloadCache.load(key: "account:\(id)") else { return nil }
        return try? JSONDecoder().decode(PublicSchema.AccountsSelect.self, from: data)
    }
}
