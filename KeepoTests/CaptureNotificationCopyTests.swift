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

    private func resolution(
        accountName: String?, categoryName: String, categoryIsDefault: Bool, currency: String?, minorUnit: Int?
    ) -> CaptureLocalWrite.Resolution {
        CaptureLocalWrite.Resolution(
            accountName: accountName, categoryName: categoryName, categoryIsDefault: categoryIsDefault,
            currency: currency, minorUnit: minorUnit
        )
    }

    @Test("account and category both known — success copy")
    func bothKnown() {
        let known = resolution(
            accountName: "Revolut", categoryName: "Coffee", categoryIsDefault: false, currency: "EUR", minorUnit: 2
        )
        let content = CaptureNotificationCopy.appliedLocally(known, amountE4: 45000, locale: usLocale)
        #expect(content.title == "✅ €4.50 Logged successfully")
        #expect(content.body == "Coffee · Revolut — Tap to confirm")
    }

    @Test("account unknown — asks which account, mentions the new card")
    func accountUnknown() {
        let unmapped = resolution(
            accountName: nil, categoryName: "Coffee", categoryIsDefault: false, currency: nil, minorUnit: nil
        )
        let content = CaptureNotificationCopy.appliedLocally(unmapped, amountE4: 45000, locale: usLocale)
        #expect(content.title == "💳 4.50 Logged to Coffee")
        #expect(content.body == "New card detected. Tap to select which account should be linked to")
    }

    @Test("category unknown — falls back to Other, asks what was bought")
    func categoryUnknown() {
        let defaulted = resolution(
            accountName: "Revolut", categoryName: "Other", categoryIsDefault: true, currency: "EUR", minorUnit: 2
        )
        let content = CaptureNotificationCopy.appliedLocally(defaulted, amountE4: 45000, locale: usLocale)
        #expect(content.title == "🏷️ €4.50 Logged to Revolut")
        #expect(content.body == "What did you buy? Tap to choose")
    }

    @Test("both unknown — generic logged-automatically copy")
    func bothUnknown() {
        let unknown = resolution(
            accountName: nil, categoryName: "Other", categoryIsDefault: true, currency: nil, minorUnit: nil
        )
        let content = CaptureNotificationCopy.appliedLocally(unknown, amountE4: 45000, locale: usLocale)
        #expect(content.title == "❓ 4.50 Logged automatically")
        #expect(content.body == "Tap to add missing details")
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
        let known = resolution(
            accountName: "Chase", categoryName: "Shopping", categoryIsDefault: false, currency: "USD", minorUnit: 2
        )
        let withCurrency = CaptureNotificationCopy.appliedLocally(known, amountE4: 12_345_600, locale: usLocale)
        #expect(withCurrency.title == "✅ $1,234.56 Logged successfully")

        let unmapped = resolution(
            accountName: nil, categoryName: "Shopping", categoryIsDefault: false, currency: nil, minorUnit: nil
        )
        let withoutCurrency = CaptureNotificationCopy.appliedLocally(unmapped, amountE4: 12_345_600, locale: usLocale)
        #expect(withoutCurrency.title == "💳 1,234.56 Logged to Shopping")
    }
}
