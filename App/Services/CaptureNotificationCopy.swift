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

    static func appliedLocally(
        _ resolution: CaptureLocalWrite.Resolution, amountE4: Int64, locale: Locale = .current
    ) -> Content {
        let accountKnown = resolution.accountName != nil && resolution.currency != nil
        let categoryKnown = !resolution.categoryIsDefault
        let amount = amountText(
            currency: resolution.currency, minorUnit: resolution.minorUnit, amountE4: amountE4, locale: locale
        )

        // Overrides every branch below, including "both unknown" (which
        // otherwise shows no quick-action buttons at all) — a suspected
        // duplicate is more urgent than "tap to pick a category," so it
        // wins the headline regardless of what else did or didn't resolve.
        guard !resolution.isPossibleDuplicate else {
            return Content(
                title: "⚠️ \(amount) — Possible duplicate", body: "Press for quick actions or tap to open in app"
            )
        }

        switch (accountKnown, categoryKnown) {
        case (true, true):
            return Content(
                title: "✅ \(amount) Logged successfully",
                body: "\(resolution.categoryName) · \(resolution.accountName ?? "") "
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
                body: "What did you buy? Press for quick actions or tap to open in app"
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
