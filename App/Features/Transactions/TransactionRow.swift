import KeepoCore
import SwiftUI

/// Shared by every transaction row in `TransactionsListView` — the same row
/// rendering (category icon, currency conversion label, privacy mode) in
/// one place.
///
/// Amounts render in ledger style: an expense drops its minus sign and an
/// income gains an explicit `+` in green. The stored value is untouched —
/// `amount` stays signed, and nothing here re-signs it (money rule 1). The
/// row already says which direction the money went by sitting under a
/// category and next to an account; a minus sign in front of every second
/// row is noise that makes the few genuinely negative *balances* elsewhere
/// in the app harder to notice.
struct TransactionRow: View {
    let transaction: PublicSchema.TransactionsWithDetailsSelect
    var category: PublicSchema.CategoriesSelect?
    /// The transfer's other leg, when the ledger has folded both into this
    /// one row (`TransactionEntry`). Its presence is what turns the row from
    /// "money left Checking" into "money moved Checking → Savings".
    var counterpart: PublicSchema.TransactionsWithDetailsSelect?
    var isPendingUpdate: Bool = false
    /// Set only by the Needs Review inbox, which renders this exact row so
    /// that an item waiting for review looks like the transaction it is
    /// about to become.
    ///
    /// The ledger deliberately leads with the **category**, not the
    /// merchant, and nothing here changes that. But the inbox is where the
    /// user *decides*, and "Groceries, on Amex" is not enough to decide
    /// whether a capture is real — the merchant is. So the inbox, and only
    /// the inbox, puts it ahead of the account on the second line.
    var merchant: String?

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var isTransfer: Bool { transaction.kind == "transfer" }

    /// Source and destination, worked out from the signs rather than from
    /// which leg the list happened to reach first — the ledger keeps
    /// whichever came first, and that can be either one.
    private var legs: (from: PublicSchema.TransactionsWithDetailsSelect,
                       to: PublicSchema.TransactionsWithDetailsSelect)? {
        guard let counterpart else { return nil }
        return (transaction.amountE4 ?? 0) < 0 ? (transaction, counterpart) : (counterpart, transaction)
    }

    /// The leg every figure on this row is drawn from: the outgoing one for
    /// a combined transfer, so the amount shown is the amount that left.
    private var displayed: PublicSchema.TransactionsWithDetailsSelect { legs?.from ?? transaction }

    /// A transfer between two currencies does not have "an amount" — it has
    /// one on each side. Only then is the far side worth a second line.
    private var arrivingAmount: String? {
        guard let legs, legs.from.currency != legs.to.currency else { return nil }
        guard let code = legs.to.currency, let minorUnit = legs.to.minorUnit else { return nil }
        let currency = CurrencyInfo(code: code, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(legs.to.amountE4, currency: currency, signStyle: .magnitude)
    }

    private var isCombinedTransfer: Bool { counterpart != nil }

    // `status == .pending` — an automatic capture still waiting on review,
    // never true for a manually-entered transaction (those are created
    // already `confirmed`). Distinct from `isPendingUpdate` (unsynced
    // outbox write) — this row can be fully synced and still unreviewed.
    private var isPendingReview: Bool { transaction.status == .pending }
    private var isCaptured: Bool { transaction.source == .capture }
    private var isRecurring: Bool { transaction.recurringRuleId != nil }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            if isTransfer {
                CategoryIconView(icon: "arrow.left.arrow.right", color: AppTheme.Palette.textSecondary)
            } else {
                CategoryIconView(category: category)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(headline)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .lineLimit(1)
                    if isPendingReview {
                        PendingBadge()
                    }
                    if isPendingUpdate {
                        Image(systemName: "icloud.slash")
                            .font(AppTheme.Typography.nano)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }

                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(detailLine)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                    // How this row came to exist, when it wasn't the user
                    // typing it. Glyph-only and grey: it is provenance, and
                    // spelling it out on every row would crowd out the
                    // account name, which is what people actually scan for.
                    if isCaptured {
                        KeepoIcon(name: "icon-robot", size: AppTheme.Size.glyphNano)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .accessibilityLabel("Captured automatically")
                    }
                    if isRecurring {
                        KeepoIcon(name: "icon-recurrent", size: AppTheme.Size.glyphNano)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .accessibilityLabel("Part of a recurring payment")
                    }
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)

            VStack(alignment: .trailing, spacing: AppTheme.Spacing.xxs) {
                PrivateText(formattedAmount)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if let arrivingAmount {
                    PrivateText("→ " + arrivingAmount)
                        .font(AppTheme.Typography.micro)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                } else if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: displayed.currency,
                        amountBase: displayed.amountBaseE4,
                        baseCurrency: displayed.baseCurrency,
                        baseMinorUnit: displayed.baseMinorUnit,
                        hasMissingRate: displayed.hasMissingRate ?? false,
                        signStyle: .ledger
                    )
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    /// Both accounts when the row is a whole transfer, one when it is a leg
    /// or an ordinary transaction. The arrow is the row's statement of
    /// direction, which is why the amount beside it needs no sign.
    private var accountLine: String {
        guard let legs else { return transaction.accountName ?? "—" }
        return "\(legs.from.accountName ?? "—") → \(legs.to.accountName ?? "—")"
    }

    /// What the row is called: the user's own title when they gave it one,
    /// otherwise the category — or "Transfer", which is a transfer's
    /// category in all but name.
    private var headline: String {
        if let title = transaction.title { return title }
        return isTransfer ? "Transfer" : (transaction.categoryName ?? "—")
    }

    /// The second line as drawn: the account alone on the ledger, the
    /// merchant and then the account in the inbox. See `merchant`.
    ///
    /// **A title pushes the category down here** rather than off the row. The
    /// icon still says it, but an icon is a colour and a glyph, and "which
    /// category did I file this under" is a question the ledger has always
    /// answered in words. A transfer has none to move — its arrow is already
    /// in the account line.
    private var detailLine: String {
        var parts: [String] = []
        if let merchant, !merchant.isEmpty { parts.append(merchant) }
        if transaction.title != nil, !isTransfer, let category = transaction.categoryName {
            parts.append(category)
        }
        parts.append(accountLine)
        return parts.joined(separator: " · ")
    }

    private var formattedAmount: String {
        guard let currencyCode = displayed.currency, let minorUnit = displayed.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        // `.magnitude`, not `.ledger`: a combined transfer is neither an
        // inflow nor an outflow — the money is still the user's — so the
        // row draws the figure alone and lets the arrow say the rest.
        return MoneyFormatter.format(
            displayed.amountE4, currency: currency, signStyle: isCombinedTransfer ? .magnitude : .ledger
        )
    }

    /// Green means "money arrived", by sign rather than by kind — which also
    /// gives a transfer's receiving leg the same treatment as income, since
    /// from the destination account's point of view that is exactly what it
    /// is. Outflows stay in the primary text colour rather than going red:
    /// spending is the normal case, and colouring every expense as an alert
    /// makes the colour mean nothing.
    /// A combined transfer is exempt: green would say money arrived, and
    /// across the pair nothing did.
    private var amountColor: Color {
        guard !isCombinedTransfer, let amount = transaction.amountE4, amount > 0 else {
            return AppTheme.Palette.textPrimary
        }
        return AppTheme.Palette.statusPositive
    }
}

/// A capture still waiting on review, in the ledger — where a row has
/// neighbours and has to say for itself which of them is the unreviewed
/// one. `PendingEdgeStrip` is the same fact on the form, where it isn't.
struct PendingBadge: View {
    var body: some View {
        Text("Pending")
            .font(AppTheme.Typography.nanoEmphasis)
            .foregroundStyle(AppTheme.Palette.brandPrimary)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.fill), in: Capsule())
    }
}

/// The same "still waiting on review", said with a band across the top of
/// the form's card.
///
/// The form used to show `PendingBadge` beside the date, which made the
/// header a two-item row for a fact that belongs to the whole entry rather
/// than to anything in it — and took the space the day stepper now uses.
/// The band states it once, across the edge, and stands in nothing's way.
///
/// It carries the word as well as the colour for the same reason the badge
/// did: `brandPrimary` at `Opacity.fill` is a wash, and a wash alone is a
/// status only the people who already know the convention can read.
///
/// Full-bleed by design — it has no corner radius of its own and relies on
/// the card clipping it, which is why the card composes it **in the stack**
/// rather than as an overlay. An overlay version of this shipped for about
/// an hour and ate every tap on the card: it was the card's own shape with
/// only its *drawing* masked to the top edge, and a mask does not narrow
/// hit testing.
struct PendingEdgeStrip: View {
    var body: some View {
        Text("Pending")
            .font(AppTheme.Typography.nanoEmphasis)
            .foregroundStyle(AppTheme.Palette.brandPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.fill))
    }
}
