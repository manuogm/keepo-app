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
/// see `CaptureIntent.notify(title:body:transactionId:)`.
enum CaptureNotificationCopy {
    struct Content: Equatable {
        let title: String
        let body: String
    }

    static func appliedLocally(
        _ resolution: CaptureLocalWrite.Resolution, amountE4: Int64, locale: Locale = .current
    ) -> Content {
        let accountKnown = resolution.accountName != nil && resolution.currency != nil
        let categoryKnown = !resolution.categoryIsDefault
        let amount = amountText(
            currency: resolution.currency, minorUnit: resolution.minorUnit, amountE4: amountE4, locale: locale
        )

        switch (accountKnown, categoryKnown) {
        case (true, true):
            return Content(
                title: "✅ \(amount) Logged successfully",
                body: "\(resolution.categoryName) · \(resolution.accountName ?? "") — Tap to confirm"
            )
        case (false, true):
            return Content(
                title: "💳 \(amount) Logged to \(resolution.categoryName)",
                body: "New card detected. Tap to select which account should be linked to"
            )
        case (true, false):
            return Content(
                title: "🏷️ \(amount) Logged to \(resolution.accountName ?? "")",
                body: "What did you buy? Tap to choose"
            )
        case (false, false):
            return Content(title: "❓ \(amount) Logged automatically", body: "Tap to add missing details")
        }
    }

    /// The rare RPC-only fallback (`OutboxCaptureResult.applied`) — the row
    /// landed server-side with nothing local to describe it yet, so
    /// neither account nor category is knowable here either. Same copy as
    /// the both-unknown branch above.
    static func applied(amountE4: Int64, locale: Locale = .current) -> Content {
        let amount = amountText(currency: nil, minorUnit: nil, amountE4: amountE4, locale: locale)
        return Content(title: "❓ \(amount) Logged automatically", body: "Tap to add missing details")
    }

    static func queued(amountE4: Int64, locale: Locale = .current) -> Content {
        let amount = amountText(currency: nil, minorUnit: nil, amountE4: amountE4, locale: locale)
        return Content(title: "⚠️ \(amount) Saved Locally", body: "Sign back in to sync this expense")
    }

    /// A real currency renders with `MoneyFormatter`; an unresolved one
    /// falls back to a plain, unsigned decimal — money rule 5, never a
    /// guessed currency symbol for a value that isn't actually known.
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
    private static func amountText(currency: String?, minorUnit: Int?, amountE4: Int64, locale: Locale) -> String {
        guard let currency else { return plainAmountText(amountE4, locale: locale) }
        return MoneyFormatter.format(
            abs(amountE4), currency: CurrencyInfo(code: currency, minorUnit: minorUnit ?? 2), locale: locale
        )
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
