import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// `en_US` throughout — money/decimal rendering is locale-dependent
/// (`MoneyFormatterTests` in KeepoCoreTests does the same) and this suite
/// isn't testing formatting itself, just which copy branch fires.
@Suite("Capture notification copy")
struct CaptureNotificationCopyTests {
    let usLocale = Locale(identifier: "en_US")

    /// The ordinary capture: one currency, so the paid figure and the
    /// account's are the same thing and there is no second amount.
    private func sameCurrency(
        accountName: String?, categoryName: String, categoryIsDefault: Bool, currency: String?,
        amountE4: Int64 = -45000, isPossibleDuplicate: Bool = false
    ) -> CaptureLocalWrite.Resolution {
        resolution(
            accountName: accountName, categoryName: categoryName, categoryIsDefault: categoryIsDefault,
            paidAmountE4: amountE4, paidCurrency: currency,
            accountCurrency: accountName != nil ? currency : nil,
            isPossibleDuplicate: isPossibleDuplicate
        )
    }

    private func resolution(
        accountName: String?, categoryName: String, categoryIsDefault: Bool,
        paidAmountE4: Int64, paidCurrency: String?, chargedAmountE4: Int64? = nil,
        accountCurrency: String? = nil, isPossibleDuplicate: Bool = false
    ) -> CaptureLocalWrite.Resolution {
        CaptureLocalWrite.Resolution(
            accountName: accountName, categoryName: categoryName, categoryIsDefault: categoryIsDefault,
            paidAmountE4: paidAmountE4, paidCurrency: paidCurrency, paidMinorUnit: paidCurrency == nil ? nil : 2,
            chargedAmountE4: chargedAmountE4, accountCurrency: accountCurrency,
            accountMinorUnit: accountCurrency == nil ? nil : 2,
            categoryId: UUID().uuidString, accountId: accountName != nil ? UUID().uuidString : nil,
            suggestedCategories: [], suggestedAccounts: [], isPossibleDuplicate: isPossibleDuplicate
        )
    }

    @Test("account and category both known — success copy")
    func bothKnown() {
        let known = sameCurrency(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false, currency: "EUR"
        )
        let content = CaptureNotificationCopy.appliedLocally(known, locale: usLocale)
        #expect(content.title == "✅ €4.50 Logged successfully")
        #expect(content.body == "Coffee · Revolut — Press for quick actions or tap to open in app")
    }

    @Test("account unknown — asks which account, mentions the new card")
    func accountUnknown() {
        let unmapped = sameCurrency(
            accountName: nil, categoryName: "Coffee", categoryIsDefault: false, currency: nil
        )
        let content = CaptureNotificationCopy.appliedLocally(unmapped, locale: usLocale)
        #expect(content.title == "💳 4.50 Logged to Coffee")
        #expect(content.body == "New card detected. Press for quick actions or tap to open in app")
    }

    @Test("category unknown — falls back to Other, asks what was bought")
    func categoryUnknown() {
        let defaulted = sameCurrency(
            accountName: "Revolut", categoryName: "Other", categoryIsDefault: true, currency: "EUR"
        )
        let content = CaptureNotificationCopy.appliedLocally(defaulted, locale: usLocale)
        #expect(content.title == "🏷️ €4.50 Logged to Revolut")
        #expect(content.body == "What did you buy? Press for quick actions or tap to open in app")
    }

    @Test("both unknown — generic logged-automatically copy, no swipe hint")
    func bothUnknown() {
        let unknown = sameCurrency(
            accountName: nil, categoryName: "Other", categoryIsDefault: true, currency: nil
        )
        let content = CaptureNotificationCopy.appliedLocally(unknown, locale: usLocale)
        #expect(content.title == "❓ 4.50 Logged automatically")
        #expect(content.body == "Tap to add missing details")
    }

    /// The duplicate flag overrides every branch's copy, including "both
    /// unknown" — a suspected duplicate is more urgent than the usual
    /// missing-details prompt.
    @Test("possible duplicate overrides the branch copy, regardless of what else resolved")
    func possibleDuplicate() {
        let known = sameCurrency(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false, currency: "EUR",
            isPossibleDuplicate: true
        )
        let content = CaptureNotificationCopy.appliedLocally(known, locale: usLocale)
        #expect(content.title == "⚠️ €4.50 — Possible duplicate")
        #expect(content.body == "Press for quick actions or tap to open in app")

        let unknown = sameCurrency(
            accountName: nil, categoryName: "Other", categoryIsDefault: true, currency: nil,
            isPossibleDuplicate: true
        )
        let unknownContent = CaptureNotificationCopy.appliedLocally(unknown, locale: usLocale)
        #expect(unknownContent.title == "⚠️ 4.50 — Possible duplicate")
        #expect(unknownContent.body == "Press for quick actions or tap to open in app")
    }

    @Test("the rare RPC-only fallback matches the both-unknown copy")
    func appliedFallback() {
        let content = CaptureNotificationCopy.applied(amountE4: 12300, locale: usLocale)
        #expect(content.title == "❓ 1.23 Logged automatically")
        #expect(content.body == "Tap to add missing details")
    }

    @Test("signed-out/queued copy tells the user to sign back in")
    func queued() {
        let content = CaptureNotificationCopy.queued(amountE4: 5000, locale: usLocale)
        #expect(content.title == "⚠️ 0.50 Saved Locally")
        #expect(content.body == "Sign back in to sync this expense")
    }

    /// Regression: the unknown-currency fallback used to reuse
    /// `AmountFormatter.editableString` — a form-field formatter with
    /// grouping deliberately disabled — so a large amount on an unmapped
    /// card rendered as "1234.50" right next to a mapped-card notification
    /// showing "$1,234.50", which is the "inconsistent formatting"
    /// reported from real device testing. Both must group the same way now.
    @Test("an unknown-currency amount groups digits the same way a known one does")
    func unknownCurrencyAmountMatchesKnownCurrencyGrouping() {
        let known = sameCurrency(
            accountName: "Chase", categoryName: "Shopping", categoryIsDefault: false, currency: "USD",
            amountE4: -12_345_600
        )
        let withCurrency = CaptureNotificationCopy.appliedLocally(known, locale: usLocale)
        #expect(withCurrency.title == "✅ $1,234.56 Logged successfully")

        let unmapped = sameCurrency(
            accountName: nil, categoryName: "Shopping", categoryIsDefault: false, currency: nil,
            amountE4: -12_345_600
        )
        let withoutCurrency = CaptureNotificationCopy.appliedLocally(unmapped, locale: usLocale)
        #expect(withoutCurrency.title == "💳 1,234.56 Logged to Shopping")
    }

    // MARK: - A purchase in another currency

    /// **The regression this split exists for.** The copy used to be handed
    /// the paid figure and the account's currency as two unrelated
    /// arguments, so a $1,234.56 purchase on a EUR account rendered as
    /// "€1,234.56" — a number that was never paid, in a currency it was
    /// never paid in. There is no longer an amount parameter to get wrong.
    @Test("a converted purchase leads with what was paid, not the account's figure")
    func foreignLeadsWithPaidAmount() {
        let converted = resolution(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false,
            paidAmountE4: -12_345_600, paidCurrency: "USD", chargedAmountE4: -11_400_000, accountCurrency: "EUR"
        )
        let content = CaptureNotificationCopy.appliedLocally(converted, locale: usLocale)
        #expect(content.title == "✅ $1,234.56 Logged successfully")
        #expect(content.body == "€1,140.00 charged · Coffee · Revolut — Press for quick actions or tap to open in app")
    }

    @Test("the charged figure rides along on every branch that can have an account")
    func chargedFigureAcrossBranches() {
        let defaulted = resolution(
            accountName: "Revolut", categoryName: "Other", categoryIsDefault: true,
            paidAmountE4: -12_345_600, paidCurrency: "USD", chargedAmountE4: -11_400_000, accountCurrency: "EUR"
        )
        #expect(
            CaptureNotificationCopy.appliedLocally(defaulted, locale: usLocale).body
                == "€1,140.00 charged · What did you buy? Press for quick actions or tap to open in app"
        )

        let duplicate = resolution(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false,
            paidAmountE4: -12_345_600, paidCurrency: "USD", chargedAmountE4: -11_400_000, accountCurrency: "EUR",
            isPossibleDuplicate: true
        )
        #expect(
            CaptureNotificationCopy.appliedLocally(duplicate, locale: usLocale).body
                == "€1,140.00 charged · Press for quick actions or tap to open in app"
        )
    }

    /// A held capture — foreign, but no account yet, so there is nothing to
    /// have been charged. The title still names what was paid.
    @Test("a held capture names the paid currency and offers no charged figure")
    func heldCaptureHasNoChargedFigure() {
        let held = resolution(
            accountName: nil, categoryName: "Coffee", categoryIsDefault: false,
            paidAmountE4: -12_345_600, paidCurrency: "USD"
        )
        let content = CaptureNotificationCopy.appliedLocally(held, locale: usLocale)
        #expect(content.title == "💳 $1,234.56 Logged to Coffee")
        #expect(content.body == "New card detected. Press for quick actions or tap to open in app")
    }

    // MARK: - The mark Wallet printed

    /// The reported case: a new card, in a currency `CurrencyDetector`
    /// refuses to name (an ambiguous `$`), so nothing in the resolution can
    /// label the figure. The mark itself still can.
    @Test("an unresolvable currency still shows the mark Wallet printed")
    func symbolHintFillsTheGap() {
        let unmapped = sameCurrency(
            accountName: nil, categoryName: "Shopping", categoryIsDefault: false, currency: nil,
            amountE4: -12_345_600
        )
        let content = CaptureNotificationCopy.appliedLocally(
            unmapped, symbolHint: .init(token: "$", isPrefix: true), locale: usLocale
        )
        #expect(content.title == "💳 $1,234.56 Logged to Shopping")
    }

    @Test("a trailing mark stays trailing")
    func symbolHintSuffix() {
        let unmapped = sameCurrency(
            accountName: nil, categoryName: "Other", categoryIsDefault: true, currency: nil, amountE4: -45000
        )
        let content = CaptureNotificationCopy.appliedLocally(
            unmapped, symbolHint: .init(token: "kr", isPrefix: false), locale: usLocale
        )
        #expect(content.title == "❓ 4.50\u{00A0}kr Logged automatically")
    }

    /// A known currency is always the better answer — the hint is a
    /// fallback, never an override.
    @Test("a resolved currency ignores the hint")
    func resolvedCurrencyWinsOverHint() {
        let known = sameCurrency(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false, currency: "EUR"
        )
        let content = CaptureNotificationCopy.appliedLocally(
            known, symbolHint: .init(token: "$", isPrefix: true), locale: usLocale
        )
        #expect(content.title == "✅ €4.50 Logged successfully")
    }

    /// The two branches with no resolution at all — they never had a
    /// currency to show and now at least have a mark.
    @Test("the applied and queued fallbacks take the mark too")
    func fallbacksTakeTheHint() {
        let applied = CaptureNotificationCopy.applied(
            amountE4: 12300, symbolHint: .init(token: "$", isPrefix: true), locale: usLocale
        )
        #expect(applied.title == "❓ $1.23 Logged automatically")

        let queued = CaptureNotificationCopy.queued(
            amountE4: 5000, symbolHint: .init(token: "€", isPrefix: false), locale: usLocale
        )
        #expect(queued.title == "⚠️ 0.50\u{00A0}€ Saved Locally")
    }
}
