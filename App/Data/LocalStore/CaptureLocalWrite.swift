import Foundation
import GRDB
import KeepoCore
import Supabase

/// The capture write's local-first counterpart to `capture_transaction`
/// (SQL) — mirrors its exact resolution order (mapped card → merchant
/// learning → the owner's `is_default` category) so a captured purchase is
/// visible in Needs Review the instant Apple Pay fires, offline included,
/// without waiting on the round trip `Outbox`'s background attempt still
/// makes separately. `resolveAndWrite` writes under the payload's own `id`
/// — the exact id the background RPC attempt (or a queued retry) also
/// sends — so the eventual server row lands on the identical primary key
/// and the later sync pull simply confirms this guess, never disagrees
/// with it.
///
/// Unlike account resolution, category resolution is a hard requirement —
/// `transactions.category_id` stays `NOT NULL` even for an unresolved
/// capture (only `account_id`/`currency` are nullable, and only ever for
/// this exact case). The only way this fails is if the local mirror hasn't
/// synced the owner's `is_default` "Other" category yet, which returns
/// `nil` here — the caller (`Outbox.submitCaptureTransaction`) falls back
/// to its RPC-or-queue path in that rare case, same as before local-first
/// capture existed at all.
///
/// Account resolution is optional and never blocks the write: an unmapped
/// card (or one whose mapping hasn't synced down locally yet) just writes
/// `account_id`/`currency` as null — the local mirror's own counterpart to
/// what `capture_transaction` now does server-side. This file deliberately
/// never creates the `card_mappings` placeholder row an unmapped card gets
/// server-side (that row's id is server-generated — `gen_random_uuid()` —
/// so a client guess here would permanently fork into a duplicate
/// `ambiguous_card` Needs Review entry the real mapping never resolves);
/// it only ever reads that table, never writes to it.
/// `public` — `Resolution` is carried whole by `OutboxCaptureResult
/// .appliedLocally` (`Outbox.swift`), itself a `public` type, and a nested
/// type's effective access can never exceed its container's.
public enum CaptureLocalWrite {
    /// One quick-action button candidate — a category or account name paired
    /// with the id `CaptureQuickActions` needs to route a tap back to. Ids
    /// stay `String` throughout, same as every other id in this file; only
    /// the Outbox payload boundary converts to `UUID`.
    public struct Suggestion: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        init(row: Row) {
            id = row["id"]
            name = row["name"]
        }
    }

    public struct Resolution: Equatable, Sendable {
        public let accountName: String?
        public let categoryName: String
        /// True when nothing was actually learned for this merchant and
        /// resolution fell back to the owner's generic `is_default`
        /// category — the same signal `needs_review`'s own subtitle
        /// (`'Other'` vs `'Suggested: ' || c.name`) already uses to mean
        /// "not really known." Drives the notification copy's "category
        /// unknown" branch (`CaptureNotificationCopy`).
        public let categoryIsDefault: Bool
        /// **What the purchase was charged in, and the figure in it** —
        /// the pair the notification always leads with, because it is the
        /// one the user just watched the terminal print. Never converted,
        /// never the account's.
        ///
        /// `paidCurrency` is nil only when nothing could name it: an
        /// unmapped card whose mark `CurrencyDetector` would not resolve.
        /// That case renders through `SymbolHint` instead — "account
        /// unknown" is decided by `accountName`, never by this.
        public let paidAmountE4: Int64
        public let paidCurrency: String?
        public let paidMinorUnit: Int?
        /// **The account-currency figure, and only when one exists** —
        /// non-nil exactly when the purchase was foreign *and* a rate
        /// resolved, which is also exactly when the row stores an
        /// `original_amount_e4`/`original_currency` pair. Nil for every
        /// same-currency capture (there is no second figure) and for every
        /// held one (there is no account).
        ///
        /// Carried separately from `paidAmountE4` rather than as one
        /// "display amount" because collapsing them is the bug this
        /// replaced: the copy was handed the paid figure and the account's
        /// currency, and rendered a ¥5,000 purchase as "€5,000.00".
        public let chargedAmountE4: Int64?
        public let accountCurrency: String?
        public let accountMinorUnit: Int?
        /// The resolved ids themselves — `accountName`/`categoryName` alone
        /// are display-only; `CaptureQuickActions` needs the actual ids to
        /// build `ReviewCaptureTransactionPayload` and to exclude the
        /// already-applied category from its own alternates.
        public let categoryId: String
        public let accountId: String?
        /// Up to 3 alternates, ranked — empty whenever a branch doesn't use
        /// them (e.g. `suggestedAccounts` when the account already
        /// resolved). See `CaptureQuickActionSuggestions`.
        public let suggestedCategories: [Suggestion]
        public let suggestedAccounts: [Suggestion]
        /// Same card + merchant + amount as another live transaction within
        /// a 15-minute window — see `CaptureQuickActionSuggestions
        /// .hasPossibleDuplicate`. Overrides the notification's copy and
        /// button set with a duplicate warning + Delete action.
        public let isPossibleDuplicate: Bool
        /// The merchant taught Keepo nothing, and the category came from a
        /// title the user once typed that matches it exactly
        /// (`LocalTitleMemory`). This is what the outbox forwards to the
        /// server as `p_category_hint`, so the server row lands on the same
        /// category rather than the default and does not flip the row on the
        /// next pull. Defaulted so the showcase and tests that build a
        /// resolution by hand need not name it.
        public var categoryFromTitle = false
    }

    static func resolveAndWrite(
        _ payload: CaptureTransactionPayload, ownerId: String, in database: Database
    ) throws -> Resolution? {
        guard let resolvedCategory = try resolveCategory(
            database, ownerId: ownerId, merchantNormalized: payload.merchantNormalized
        ) else { return nil }
        let category = resolvedCategory.row
        let categoryFromTitle = resolvedCategory.fromTitle
        let categoryId: String = category["id"]
        let categoryName: String = category["name"]
        let categoryIsDefault: Bool = category["is_default"]

        let account = try mappedAccount(database, ownerId: ownerId, cardIdentifier: payload.cardIdentifier)
        let resolved = try resolveCurrency(database, payload: payload, account: account)
        let accountId = resolved.accountId
        let accountName = resolved.accountName
        let paidMinorUnit = try minorUnit(database, of: resolved.paidCurrency)
        let accountMinorUnit = try minorUnit(database, of: resolved.accountCurrency)

        let quickActions = try quickActionData(
            database, ownerId: ownerId, payload: payload, accountId: accountId, category: category
        )

        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(ownerId), "created_by": .string(ownerId),
                "account_id": accountId.map(AnyJSON.string) ?? .null, "category_id": .string(categoryId),
                "amount_e4": .integer(Int(resolved.amountE4)),
                "currency": resolved.accountCurrency.map(AnyJSON.string) ?? .null,
                "original_amount_e4": resolved.original.map { AnyJSON.integer(Int($0.amountE4)) } ?? .null,
                "original_currency": resolved.original.map { AnyJSON.string($0.currency) } ?? .null,
                "occurred_at": .string(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt)),
                "merchant_raw": .string(payload.merchantRaw),
                "merchant_normalized": .string(payload.merchantNormalized),
                "notes": payload.notes.map(AnyJSON.string) ?? .null, "card_identifier": .string(payload.cardIdentifier),
                "source": .string("capture"), "status": .string("pending"), "external_id": .string(payload.externalId),
                "version": .integer(1), "created_at": .string(now), "updated_at": .string(now), "sync_seq": .integer(0)
            ],
            table: "transactions", in: database
        )

        return Resolution(
            accountName: accountName, categoryName: categoryName, categoryIsDefault: categoryIsDefault,
            paidAmountE4: resolved.paidAmountE4, paidCurrency: resolved.paidCurrency,
            paidMinorUnit: paidMinorUnit, chargedAmountE4: resolved.chargedAmountE4,
            accountCurrency: resolved.accountCurrency, accountMinorUnit: accountMinorUnit,
            categoryId: categoryId, accountId: accountId,
            suggestedCategories: quickActions.categories, suggestedAccounts: quickActions.accounts,
            isPossibleDuplicate: quickActions.isPossibleDuplicate,
            categoryFromTitle: categoryFromTitle
        )
    }

    /// What `amount_e4`, `currency` and the original pair should be — the
    /// local port of `capture_transaction`'s currency arm
    /// (`20260923100000_transaction_original_currency.sql`). The two must
    /// agree: this runs the instant Apple Pay fires and the RPC runs
    /// whenever the network allows, both writing the same primary key, so a
    /// disagreement is a row that changes under the user at the next pull.
    ///
    /// The conversion is `LocalMoneyConversion.convert`, the SQLite port of
    /// `fx_convert` that the referee test in `KeepoTests` already holds
    /// byte-exact against Postgres — so an offline capture and an online
    /// one produce the identical figure rather than merely a close one.
    /// `cm.deleted_at IS NULL` (20260901100000's fix A) — an unmapped card
    /// must resolve to no account locally too, matching
    /// `capture_transaction`'s own fix; without it, a card the user had
    /// unmapped kept silently auto-filing new captures into the account it
    /// used to belong to.
    private static func mappedAccount(
        _ database: Database, ownerId: String, cardIdentifier: String
    ) throws -> Row? {
        try Row.fetchOne(
            database,
            sql: """
            SELECT a.id, a.name, a.currency FROM card_mappings cm
            JOIN accounts a ON a.id = cm.account_id
            WHERE cm.owner_id = ? AND cm.card_identifier = ? AND cm.account_id IS NOT NULL
              AND cm.deleted_at IS NULL AND a.deleted_at IS NULL
            """,
            arguments: [ownerId, cardIdentifier]
        )
    }

    private struct ResolvedCurrency {
        let accountId: String?
        let accountName: String?
        /// Null exactly when `accountId` is — `account_currency_together`.
        let accountCurrency: String?
        let amountE4: Int64
        let original: ForeignOriginal?

        /// What the purchase was actually charged in — the stored figure
        /// itself whenever no conversion happened, and the held original
        /// whenever one did. The two are never the same number, which is
        /// why the notification reads these rather than `amountE4`.
        var paidAmountE4: Int64 { original?.amountE4 ?? amountE4 }
        var paidCurrency: String? { original?.currency ?? accountCurrency }
        /// The converted figure, and nil unless a conversion actually
        /// produced one: an `original` with no account currency is a held
        /// capture, which has nothing to have been charged to yet.
        var chargedAmountE4: Int64? {
            guard original != nil, accountCurrency != nil else { return nil }
            return amountE4
        }
    }

    private static func resolveCurrency(
        _ database: Database, payload: CaptureTransactionPayload, account: Row?
    ) throws -> ResolvedCurrency {
        let accountId: String? = account?["id"]
        let accountName: String? = account?["name"]
        let paid = -abs(payload.amountE4)
        let unchanged = ResolvedCurrency(
            accountId: accountId, accountName: accountName, accountCurrency: account?["currency"],
            amountE4: paid, original: nil
        )
        // A currency the local mirror cannot price is the same as none
        // detected — the same re-check the server makes rather than taking
        // the detector's word for it.
        guard let detected = try supportedCurrency(database, payload.detectedCurrency) else { return unchanged }

        guard let accountCurrency = account?["currency"] as String? else {
            // The card is not mapped, so there is no account currency to
            // compare against. Hold the pair; the review form converts once
            // the user picks an account — which is also the first moment a
            // human sees the number, the property money rule 6 turns on.
            return ResolvedCurrency(
                accountId: nil, accountName: nil, accountCurrency: nil, amountE4: paid,
                original: ForeignOriginal(amountE4: paid, currency: detected)
            )
        }
        guard detected != accountCurrency else { return unchanged }

        let occurredDate = String(PostgresDate.sqliteTimestampBoundaryString(payload.occurredAt).prefix(10))
        guard let converted = try LocalMoneyConversion.convert(
            database, amountE4: paid, from: detected, toCurrency: accountCurrency, date: occurredDate
        ) else {
            // No resolvable rate: there is no number that belongs in this
            // account's currency, so the row claims no account rather than
            // inventing one (money rule 5). The server-side trigger asks
            // for a rate backfill on the same insert, so the review form
            // usually has one by the time it is opened.
            return ResolvedCurrency(
                accountId: nil, accountName: nil, accountCurrency: nil, amountE4: paid,
                original: ForeignOriginal(amountE4: paid, currency: detected)
            )
        }
        return ResolvedCurrency(
            accountId: accountId, accountName: accountName, accountCurrency: accountCurrency,
            amountE4: converted, original: ForeignOriginal(amountE4: paid, currency: detected)
        )
    }

    private static func minorUnit(_ database: Database, of code: String?) throws -> Int? {
        try code.flatMap {
            try Int.fetchOne(database, sql: "SELECT minor_unit FROM currencies WHERE code = ?", arguments: [$0])
        }
    }

    private static func supportedCurrency(_ database: Database, _ code: String?) throws -> String? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { return nil }
        let exists = try Bool.fetchOne(
            database, sql: "SELECT EXISTS(SELECT 1 FROM currencies WHERE code = ?)", arguments: [normalized]
        )
        return exists == true ? normalized : nil
    }

    private struct QuickActionData {
        let categories: [Suggestion]
        let accounts: [Suggestion]
        let isPossibleDuplicate: Bool
    }

    /// Combines the quick-action suggestions and the duplicate check into
    /// one call, purely so `resolveAndWrite` only has one statement to make
    /// (parameter- and body-length lint thresholds, same reasoning as every
    /// other split in this file).
    private static func quickActionData(
        _ database: Database, ownerId: String, payload: CaptureTransactionPayload, accountId: String?, category: Row
    ) throws -> QuickActionData {
        let (categories, accounts) = try quickActionSuggestions(
            database, ownerId: ownerId, payload: payload, accountId: accountId, category: category
        )
        let isPossibleDuplicate = try CaptureQuickActionSuggestions.hasPossibleDuplicate(
            database, ownerId: ownerId,
            candidate: .init(
                cardIdentifier: payload.cardIdentifier, merchantNormalized: payload.merchantNormalized,
                amountE4: -abs(payload.amountE4), occurredAt: payload.occurredAt
            ),
            excluding: payload.id.uuidString
        )
        return QuickActionData(categories: categories, accounts: accounts, isPossibleDuplicate: isPossibleDuplicate)
    }

    /// Only fetches what the eventual notification branch can actually use
    /// (`CaptureNotificationCopy`'s own four-way split). Account unknown:
    /// candidate accounts. Category unknown (`categoryIsDefault`): straight
    /// to the account's own history — there's no learned category for this
    /// merchant to rank alternates against, so a merchant lookup here would
    /// almost always come back empty anyway (`resolveCategory` already
    /// checked `merchant_category_map`). Category *known* ("successful
    /// purchase"): the merchant's own history first, since it's the
    /// strongest signal for a genuine alternate; only falls back to the
    /// account's general history when this merchant has none of its own.
    /// Both known and both unknown branches fetch nothing extra — the first
    /// needs no account suggestions, the second shows no quick-action
    /// buttons at all unless `isPossibleDuplicate` overrides it with a bare
    /// Delete, which needs no suggestions either.
    private static func quickActionSuggestions(
        _ database: Database, ownerId: String, payload: CaptureTransactionPayload, accountId: String?, category: Row
    ) throws -> (categories: [Suggestion], accounts: [Suggestion]) {
        guard let accountId else {
            return (
                [],
                try CaptureQuickActionSuggestions.topUnmappedAccounts(
                    database, ownerId: ownerId, cardIdentifier: payload.cardIdentifier, limit: 3
                )
            )
        }
        let categoryIsDefault: Bool = category["is_default"]
        guard !categoryIsDefault else {
            return (
                try CaptureQuickActionSuggestions.topCategoriesForAccount(
                    database, ownerId: ownerId, accountId: accountId, excluding: nil, limit: 3
                ),
                []
            )
        }
        let categoryId: String = category["id"]
        let byMerchant = try CaptureQuickActionSuggestions.topCategoriesForMerchant(
            database, ownerId: ownerId, merchantNormalized: payload.merchantNormalized,
            excluding: categoryId, limit: 3
        )
        guard byMerchant.isEmpty else { return (byMerchant, []) }
        return (
            try CaptureQuickActionSuggestions.topCategoriesForAccount(
                database, ownerId: ownerId, accountId: accountId, excluding: categoryId, limit: 3
            ),
            []
        )
    }

    /// Learned merchant, then a title the user typed that matches the
    /// merchant exactly, then the owner's default — `resolve_category_for
    /// _merchant`'s order, with this device's title match standing where the
    /// server takes the hint. `fromTitle` is what tells the outbox to send
    /// that hint.
    private static func resolveCategory(
        _ database: Database, ownerId: String, merchantNormalized: String
    ) throws -> (row: Row, fromTitle: Bool)? {
        if let learned = try Row.fetchOne(
            database,
            sql: """
            SELECT c.id, c.name, c.is_default FROM merchant_category_map m
            JOIN categories c ON c.id = m.category_id
            WHERE m.owner_id = ? AND m.merchant_pattern = ? AND c.kind = 'expense' AND c.deleted_at IS NULL
            """,
            arguments: [ownerId, merchantNormalized]
        ) {
            return (learned, false)
        }
        if let titled = try LocalTitleMemory.category(
            forUnlearnedMerchant: merchantNormalized, ownerId: ownerId, in: database
        ) {
            return (titled, true)
        }
        return try Row.fetchOne(
            database,
            sql: """
            SELECT id, name, is_default FROM categories
            WHERE owner_id = ? AND kind = 'expense' AND is_default = 1 AND deleted_at IS NULL
            LIMIT 1
            """,
            arguments: [ownerId]
        ).map { ($0, false) }
    }
}
