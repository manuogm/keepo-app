import Foundation
import KeepoCore

/// The Wallet-automation notification's text — split out of `CaptureIntent`
/// so the copy itself is unit-testable without an App Intent context.
///
/// Five scenarios, keyed on what a capture actually resolved (account
/// mapped? category learned, or just the generic `is_default` fallback?):
/// both known, account unknown, category unknown, both unknown, and the
/// signed-out/queued case, which has no local resolution at all. `title`
/// renders as the notification's bold first row, `body` as its second —
/// see `CaptureNotificationScheduler.scheduleAppliedLocally` for the branch
/// that pairs this copy with quick-action buttons, and `CaptureIntent
/// .notify(title:body:transactionId:)` for the plain fallback ones.
///
/// "Press", never "Swipe" — the swipe-to-reveal gesture is unreliable in
/// practice on a real device (device-testing feedback), and long-press is
/// both the gesture that actually works and the one users reach for.
enum CaptureNotificationCopy {
    struct Content: Equatable {
        let title: String
        let body: String
    }

    /// - Parameter symbolHint: the currency mark Wallet printed, for the
    ///   one case nothing else can name the currency — an unmapped card
    ///   charged in a mark `CurrencyDetector` would not resolve. Ignored
    ///   whenever a real currency is known, which is almost always.
    static func appliedLocally(
        _ resolution: CaptureLocalWrite.Resolution,
        symbolHint: CurrencyDetector.SymbolHint? = nil,
        locale: Locale = .current
    ) -> Content {
        let accountKnown = resolution.accountName != nil && resolution.accountCurrency != nil
        let categoryKnown = !resolution.categoryIsDefault
        // **Always what was paid**, never the converted figure. The user is
        // reading this seconds after watching the terminal print it, and a
        // notification that answers with a different number in a different
        // currency cannot be checked at a glance — which is the only thing
        // a capture notification is for.
        let amount = amountText(
            resolution.paidAmountE4, currency: resolution.paidCurrency, minorUnit: resolution.paidMinorUnit,
            symbolHint: symbolHint, locale: locale
        )
        // Empty unless a conversion actually happened, which needs a known
        // account — so the two account-unknown branches below never carry
        // it and do not ask.
        let charged = chargedText(resolution, locale: locale)

        // Overrides every branch below, including "both unknown" (which
        // otherwise shows no quick-action buttons at all) — a suspected
        // duplicate is more urgent than "tap to pick a category," so it
        // wins the headline regardless of what else did or didn't resolve.
        guard !resolution.isPossibleDuplicate else {
            return Content(
                title: "⚠️ \(amount) — Possible duplicate",
                body: charged + "Press for quick actions or tap to open in app"
            )
        }

        switch (accountKnown, categoryKnown) {
        case (true, true):
            return Content(
                title: "✅ \(amount) Logged successfully",
                body: charged + "\(resolution.categoryName) · \(resolution.accountName ?? "") "
                    + "— Press for quick actions or tap to open in app"
            )
        case (false, true):
            return Content(
                title: "💳 \(amount) Logged to \(resolution.categoryName)",
                body: "New card detected. Press for quick actions or tap to open in app"
            )
        case (true, false):
            return Content(
                title: "🏷️ \(amount) Logged to \(resolution.accountName ?? "")",
                body: charged + "What did you buy? Press for quick actions or tap to open in app"
            )
        case (false, false):
            return Content(title: "❓ \(amount) Logged automatically", body: "Tap to add missing details")
        }
    }

    /// What the account was actually charged, as a body prefix — the half
    /// of a foreign purchase the title deliberately does not show.
    ///
    /// The title answers "did Keepo see what I just paid?"; this answers
    /// "and what did that cost the account?", which is the figure the
    /// balance moved by and the one worth correcting against the bank's
    /// own. Both are needed and neither fits in one line, so they split
    /// across the notification's two.
    private static func chargedText(_ resolution: CaptureLocalWrite.Resolution, locale: Locale) -> String {
        guard let charged = resolution.chargedAmountE4, let currency = resolution.accountCurrency else { return "" }
        let amount = MoneyFormatter.format(
            abs(charged), currency: CurrencyInfo(code: currency, minorUnit: resolution.accountMinorUnit ?? 2),
            locale: locale
        )
        return "\(amount) charged · "
    }

    /// The rare RPC-only fallback (`OutboxCaptureResult.applied`) — the row
    /// landed server-side with nothing local to describe it yet, so
    /// neither account nor category is knowable here either. Same copy as
    /// the both-unknown branch above.
    static func applied(
        amountE4: Int64, symbolHint: CurrencyDetector.SymbolHint? = nil, locale: Locale = .current
    ) -> Content {
        let amount = amountText(
            amountE4, currency: nil, minorUnit: nil, symbolHint: symbolHint, locale: locale
        )
        return Content(title: "❓ \(amount) Logged automatically", body: "Tap to add missing details")
    }

    static func queued(
        amountE4: Int64, symbolHint: CurrencyDetector.SymbolHint? = nil, locale: Locale = .current
    ) -> Content {
        let amount = amountText(
            amountE4, currency: nil, minorUnit: nil, symbolHint: symbolHint, locale: locale
        )
        return Content(title: "⚠️ \(amount) Saved Locally", body: "Sign back in to sync this expense")
    }

    /// A real currency renders with `MoneyFormatter`. An unresolved one
    /// falls back to the mark Wallet itself printed, which is not a guess —
    /// it is the input echoed back, and `CurrencyDetector.symbol` never
    /// turns it into a code (money rule 5 is about inventing a *value*, and
    /// nothing here does). Only a string that carried no mark at all still
    /// renders as a bare decimal.
    ///
    /// Without a code there is no `minor_unit` either, so the fallback is
    /// fixed at 2 — every supported currency's own value, and wrong only
    /// for a zero-decimal one Keepo does not yet support.
    ///
    /// The fallback deliberately does NOT reuse `AmountFormatter
    /// .editableString` — that formatter is for an editable form field
    /// (`usesGroupingSeparator = false`, so a user's cursor position stays
    /// predictable while typing), not a read-only display, and reusing it
    /// here was the actual "inconsistent formatting" a user could
    /// notice: consecutive captures alternated between a grouped currency
    /// amount ("$1,234.50") and an ungrouped bare decimal ("1234.50")
    /// purely depending on whether that particular card happened to be
    /// mapped yet. This uses the same grouped decimal style
    /// `MoneyFormatter` itself applies, just without a currency symbol.
    private static func amountText(
        _ amountE4: Int64, currency: String?, minorUnit: Int?,
        symbolHint: CurrencyDetector.SymbolHint?, locale: Locale
    ) -> String {
        if let currency {
            return MoneyFormatter.format(
                abs(amountE4), currency: CurrencyInfo(code: currency, minorUnit: minorUnit ?? 2), locale: locale
            )
        }
        let plain = plainAmountText(amountE4, locale: locale)
        return symbolHint?.applied(to: plain) ?? plain
    }

    private static func plainAmountText(_ amountE4: Int64, locale: Locale) -> String {
        let magnitude = Decimal(amountE4.magnitude) / Decimal(10_000)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: magnitude as NSDecimalNumber) ?? "\(magnitude)"
    }
}

extension CaptureNotificationCopy {
    /// The four notifications onboarding shows, as the **resolutions that
    /// produce them** rather than as four hand-written cards.
    ///
    /// A capture's notification is not one message: what it says, and which
    /// buttons a long press reveals, is decided entirely by what resolved —
    /// whether the card is mapped to an account, whether the merchant taught
    /// Keepo a category, and whether it looks like a duplicate. The
    /// permission screen is asking the user to accept all four, so it shows
    /// all four; and it shows them by handing these to the same
    /// `appliedLocally` and `CaptureQuickActions.build` that production
    /// calls, so a card here cannot promise a shape the real thing does not
    /// have.
    ///
    /// - Parameter currency: the user's own base currency where it is known
    ///   yet. Setting up in euros and being shown four dollar amounts is a
    ///   small thing that makes the whole screen read as stock artwork.
    static func showcase(currency: String?) -> [CaptureLocalWrite.Resolution] {
        let code = currency ?? "USD"
        return [
            // Everything resolved: the case most captures land in once
            // Keepo has seen a merchant before.
            resolution(
                account: "Checking", category: "Groceries", categoryIsDefault: false, currency: code,
                suggestedCategories: [suggestion("Dining"), suggestion("Household")]
            ),
            // Account known, category not — the buttons are the guesses.
            resolution(
                account: "Checking", category: "Other", categoryIsDefault: true, currency: code,
                suggestedCategories: [suggestion("Groceries"), suggestion("Dining"), suggestion("Transport")]
            ),
            // A card Keepo has never seen. Nothing is wrong; it just does
            // not know which account paid yet.
            resolution(
                account: nil, category: "Groceries", categoryIsDefault: false, currency: code,
                suggestedAccounts: [suggestion("Checking"), suggestion("Savings"), suggestion("Credit Card")]
            ),
            // The one that overrides every branch above, and the one worth
            // having notifications on for: the same card, merchant and
            // amount twice inside fifteen minutes.
            resolution(
                account: "Checking", category: "Groceries", categoryIsDefault: false, currency: code,
                suggestedCategories: [suggestion("Dining")], isPossibleDuplicate: true
            )
        ]
    }

    /// The amount every showcase card carries. One figure across all four,
    /// so the eye compares the *messages* rather than re-reading a number
    /// that changed for no reason. Private: the resolutions carry it
    /// themselves now, so the card view never has to name an amount.
    private static let showcaseAmountE4: Int64 = 123_400

    private static func suggestion(_ name: String) -> CaptureLocalWrite.Suggestion {
        CaptureLocalWrite.Suggestion(id: name, name: name)
    }

    private static func resolution(
        account: String?, category: String, categoryIsDefault: Bool, currency: String,
        suggestedCategories: [CaptureLocalWrite.Suggestion] = [],
        suggestedAccounts: [CaptureLocalWrite.Suggestion] = [],
        isPossibleDuplicate: Bool = false
    ) -> CaptureLocalWrite.Resolution {
        CaptureLocalWrite.Resolution(
            accountName: account,
            categoryName: category,
            categoryIsDefault: categoryIsDefault,
            paidAmountE4: -showcaseAmountE4,
            paidCurrency: currency,
            paidMinorUnit: 2,
            // No showcase card is a foreign purchase: four cards already
            // carry four different resolutions, and a fifth axis on top of
            // them would teach the currency rule at the cost of the one
            // the screen is actually about (which buttons a press reveals).
            chargedAmountE4: nil,
            accountCurrency: account != nil ? currency : nil,
            accountMinorUnit: account != nil ? 2 : nil,
            categoryId: category,
            // `CaptureQuickActions` decides "account known" on the *id*
            // while the copy decides it on the name, so both have to agree
            // or a card would show one branch's words over another's
            // buttons.
            accountId: account,
            suggestedCategories: suggestedCategories,
            suggestedAccounts: suggestedAccounts,
            isPossibleDuplicate: isPossibleDuplicate
        )
    }
}
