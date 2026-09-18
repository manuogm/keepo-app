import KeepoCore
import SwiftUI

/// One inbox item, and everything needed to draw it the way the ledger
/// would.
///
/// `needs_review` is a stable eight-column contract (kind, item_id,
/// account_id, occurred_at, title, subtitle, amount, currency), which is
/// enough to *list* an item and nowhere near enough to make it look like a
/// transaction — it has no category, no colour, no account name. So the
/// panel loads the real row behind each pending capture alongside it.
struct NeedsReviewItem: Identifiable {
    let item: PublicSchema.NeedsReviewSelect
    /// The ledger row behind a `pending_capture` — nil for every other
    /// kind, because a sync conflict and an unmapped card are not
    /// transactions and have none.
    ///
    /// **Display only.** Confirm, Delete and the review form each re-read
    /// the row at the moment they act: all three carry an `expectedVersion`,
    /// and this copy is only as fresh as the last refresh.
    let transaction: PublicSchema.TransactionsWithDetailsSelect?
    /// The transaction's category, for the icon and its colour.
    let category: PublicSchema.CategoriesSelect?

    var id: UUID? { item.itemId }
}

/// The row itself.
///
/// A pending capture renders through **`TransactionRow`** — the ledger's
/// own row, not a copy of it. The inbox used to draw its own: a grey SF
/// Symbol, "Review capture — Walmart" and "Suggested: Groceries", which
/// looked like a settings list parked on top of a ledger. Reusing the real
/// row means the category's icon and colour, the Pending badge, the capture
/// glyph and ledger-style amounts all arrive for free, and the inbox can
/// never drift away from the list it sits above.
///
/// The other kinds are not transactions, so they keep a row of their own —
/// built from the same pieces at the same metrics, so the two read as one
/// list rather than two.
struct NeedsReviewRow: View {
    let entry: NeedsReviewItem
    let minorUnit: Int

    var body: some View {
        if let transaction = entry.transaction {
            TransactionRow(
                transaction: transaction,
                category: entry.category,
                // Normalized first: the raw descriptor is a card-statement
                // string ("SQ *BLUE BOTTLE COFFEE 00042") that eats the
                // whole line and pushes the account name off the end of it.
                // The normalized form is the same merchant with the
                // aggregator prefix and store number already stripped, and
                // it is what the app itself treats as the merchant's
                // identity. The raw string is still on the review form,
                // where provenance is the point.
                merchant: transaction.merchantNormalized ?? transaction.merchantRaw
            )
        } else {
            notATransaction
        }
    }

    private var notATransaction: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: iconName, color: AppTheme.Palette.textSecondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(entry.item.title ?? "—")
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = entry.item.subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)

            // Neither kind here carries one today. It stays because the
            // column contract does, and a later branch that has an amount
            // should not have to come back and add this.
            if let amount = entry.item.amountE4, let currencyCode = entry.item.currency {
                Text(MoneyFormatter.format(amount, currency: CurrencyInfo(code: currencyCode, minorUnit: minorUnit)))
                    .font(AppTheme.Typography.bodyEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    /// Plain glyphs, because these sit inside a 32pt filled circle at a
    /// little under half its width — a badged, multi-part symbol is mush at
    /// that size, which is what the old `creditcard.trianglebadge.exclamationmark`
    /// was.
    private var iconName: String {
        switch entry.item.kind {
        case "sync_conflict": return "arrow.triangle.2.circlepath"
        case "ambiguous_card": return "creditcard"
        default: return "questionmark"
        }
    }
}
