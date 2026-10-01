import Foundation
import GRDB
import KeepoCore

/// The user's own currencies, most important first — what the currency
/// wheel's pills are built from (`CurrencyShortcuts`).
///
/// **Cached so the wheel can read it synchronously.** Working it out is one
/// cheap query, but the wheel's sheet draws before any database read can
/// return, so without a cache every opening would show EUR/USD/GBP for a
/// frame and then swap them. The wheel reads this list through
/// `@AppStorage`, which also redraws it whenever `refresh` writes a new one.
///
/// **Refreshed when the data changes, not on a timer**: `MainTabView`
/// calls `refresh` on every `session.refresh` bump, which every write and
/// every sync pull already makes — so a new account in a new currency is
/// in the pills by the next time the wheel opens, and nothing runs while
/// nothing changes.
///
/// Device-local, and cleared on sign-out: which currencies someone holds is
/// data about their money, and must not outlive their session on a shared
/// device.
enum PreferredCurrencyCache {
    /// Comma-separated codes, most important first. For `@AppStorage`.
    static let key = AppSettingsKeys.preferredCurrencies

    static func codes(from raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }

    /// What counts as a currency the user holds: their **own** open
    /// accounts — not a household partner's shared with them, which are the
    /// partner's currencies, and not archived ones — plus their base
    /// currency, so a user whose base is SEK is offered SEK before they have
    /// opened a SEK account. Currencies merely paid in abroad do not count:
    /// one trip to Tokyo should not put JPY on the account form.
    @MainActor
    static func refresh(session: SessionStore) async {
        guard let ownerId = session.profile?.id.uuidString else { return }
        let baseCurrency = session.profile?.baseCurrency
        let usage = try? await session.dbQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT a.currency AS code,
                           COUNT(DISTINCT a.id) AS accounts,
                           COUNT(t.id) AS transactions
                    FROM accounts a
                    LEFT JOIN transactions t ON t.account_id = a.id AND t.deleted_at IS NULL
                    WHERE a.owner_id = ? AND a.deleted_at IS NULL AND a.archived_at IS NULL
                    GROUP BY a.currency
                    """,
                arguments: [ownerId]
            )
            .map { row in
                CurrencyShortcuts.Usage(code: row["code"], transactions: row["transactions"], accounts: row["accounts"])
            }
        }
        // A failed read keeps the last good list rather than blanking the
        // pills back to the defaults.
        guard var usage else { return }
        if let baseCurrency, !usage.contains(where: { $0.code == baseCurrency }) {
            usage.append(CurrencyShortcuts.Usage(code: baseCurrency, transactions: 0, accounts: 0))
        }
        let ranked = CurrencyShortcuts.rank(usage).joined(separator: ",")
        if UserDefaults.standard.string(forKey: key) != ranked {
            UserDefaults.standard.set(ranked, forKey: key)
        }
    }

    /// Called from `SessionStore.signOut()`.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
