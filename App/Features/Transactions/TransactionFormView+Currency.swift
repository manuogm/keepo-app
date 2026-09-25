import KeepoCore
import SwiftUI

// The "paid in another currency" half of TransactionFormView — the two
// bindings, what the derived charge depends on, and the derivation itself.
// Split out of that file for the project's file-length and type-body-length
// lints, same precedent as TransactionFormView+Transfer.swift.
//
// The `@State` these read stays in the main declaration; only the derived
// values live here, plus `applyForeignAmounts` (prefill from an existing
// row), `refreshConversion` (derive the charge) and `resolveLedgerAmounts`
// (what the two fields store) — here rather than in +Data.swift because
// what they are about is this, not loading or saving.

extension TransactionFormView {
    /// The wheel needs a concrete code; the form stores `nil` for "the
    /// account's own". This is the one place the two meanings meet, and
    /// writing the account's own code back through it resets to `nil` so
    /// the common case never carries a redundant original.
    var paidCurrencyBinding: Binding<String> {
        Binding(
            get: { paidCurrencyCode ?? fromAccount?.currency ?? "" },
            set: { paidCurrencyCode = ($0 == fromAccount?.currency || $0.isEmpty) ? nil : $0 }
        )
    }

    /// The charged field, with "the user typed this" folded into the
    /// setter. A `Binding` setter runs only when the CONTROL writes —
    /// `refreshConversion` assigns the state directly and so never trips it
    /// — which is exactly the distinction needed, and needs no flag or
    /// change-comparison to make.
    var chargedAmountBinding: Binding<String> {
        Binding(
            get: { chargedAmountText },
            set: {
                chargedAmountText = $0
                chargedAmountEdited = true
            }
        )
    }

    var currencyInfos: [CurrencyInfo] {
        currencies.map { CurrencyInfo(code: $0.code, minorUnit: Int($0.minorUnit)) }
    }

    /// Built here rather than inline in the card's initializer, which took
    /// the SwiftUI type checker past its limit ("unable to type-check this
    /// expression in reasonable time") — a long argument list with a
    /// ternary and five more arguments inside it.
    var foreignAmount: ForeignAmount? {
        guard kind != .transfer else { return nil }
        return ForeignAmount(
            paidCurrencyCode: $paidCurrencyCode,
            chargedText: chargedAmountBinding,
            currencies: currencyInfos,
            rateDate: conversionRateDate,
            onPickCurrency: { isPickingCurrency = true },
            onRefreshRates: { await refreshRates() }
        )
    }

    /// The no-rate escape hatch, offered on the one screen where a missing
    /// rate actually stops someone: a purchase in a currency nobody has
    /// held before, whose rate the server trigger asked for but which has
    /// not arrived yet.
    ///
    /// Goes through `FXRateSync` rather than invoking the function here, so
    /// this and Profile's "Sync Exchange Rates" row cannot drift — the
    /// mirror pull that makes a fetched rate *visible* to
    /// `LocalMoneyConversion` is the easy half to forget, and it lives
    /// there once.
    ///
    /// `chargedAmountEdited` is deliberately not reset: if the user has
    /// already typed what their bank charged, a freshly fetched reference
    /// rate must not overwrite it (money rule 6). `refreshConversion` holds
    /// that line on its own, which is why this can simply call it.
    func refreshRates() async {
        do {
            try await FXRateSync.run(session: session, invalidatesScreens: false)
            await refreshConversion()
        } catch {
            actionError = ActionError("Couldn't Refresh Exchange Rates", error)
        }
    }

    /// Everything the derived charge depends on, as one `Equatable` value.
    struct ConversionInputs: Equatable {
        let amountText: String
        let paidCurrencyCode: String?
        let accountId: UUID?
        let occurredAt: Date
    }

    var conversionInputs: ConversionInputs {
        ConversionInputs(
            amountText: amountText, paidCurrencyCode: paidCurrencyCode,
            accountId: selectedAccountId, occurredAt: occurredAt
        )
    }

    /// The purchase was made in a currency this account does not hold.
    var isForeign: Bool {
        guard kind != .transfer, let account = fromAccount, let code = paidCurrencyCode else { return false }
        return code != account.currency
    }

    /// Fills the two amount fields from a row that may or may not be
    /// foreign. The plain case is unchanged: one figure, in the account's
    /// currency, no second field.
    ///
    /// **`chargedAmountEdited` is set whenever the row already carries both
    /// halves**, and that is the load-bearing line. A foreign transaction's
    /// `amount_e4` is what the bank actually took — spread included, often
    /// typed in by hand — so re-deriving it on open would silently swap a
    /// real charge for Keepo's reference-rate estimate every time the sheet
    /// was opened. A *held* capture (no account yet, so `currency` is null)
    /// has no charge to protect and is left to derive once an account is
    /// picked, which is the whole of case (B).
    func applyForeignAmounts(_ transaction: PublicSchema.TransactionsWithDetailsSelect) {
        guard let original = transaction.originalAmountE4, let originalCurrency = transaction.originalCurrency else {
            if let amount = transaction.amountE4 {
                amountText = AmountFormatter.editableString(amount, minorUnit: Int(transaction.minorUnit ?? 2))
            }
            return
        }
        paidCurrencyCode = originalCurrency
        amountText = AmountFormatter.editableString(original, minorUnit: Int(transaction.originalMinorUnit ?? 2))
        if transaction.currency != nil, let amount = transaction.amountE4 {
            chargedAmountText = AmountFormatter.editableString(amount, minorUnit: Int(transaction.minorUnit ?? 2))
            chargedAmountEdited = true
        }
    }

    /// Re-derives the account-currency figure through
    /// `LocalMoneyConversion` — the SQLite port of `fx_convert` the referee
    /// test holds byte-exact against Postgres, so the number the user is
    /// shown offline is the number the server would have produced.
    ///
    /// Stops the moment the user edits the charge: from then on the figure
    /// is theirs, which is the entire point (money rule 6). Nothing here
    /// touches the store unless the entry is actually foreign.
    func refreshConversion() async {
        guard isForeign, let account = fromAccount, let code = paidCurrencyCode else {
            chargedAmountText = ""
            chargedAmountEdited = false
            conversionRateDate = nil
            return
        }
        guard !chargedAmountEdited else { return }
        guard let paid = AmountParser.parse(amountText), paid != 0 else {
            chargedAmountText = ""
            conversionRateDate = nil
            return
        }
        let day = String(PostgresDate.sqliteTimestampBoundaryString(occurredAt).prefix(10))
        let target = account.currency
        let converted = try? await session.dbQueue.read { database in
            try LocalMoneyConversion.convert(
                database, amountE4: paid, from: code, toCurrency: target, date: day
            )
        }
        // No rate for that pair and date — money rule 5. The field is left
        // empty and says so, rather than showing a guess or a zero. A
        // capture in a brand-new currency lands here until the backfill
        // the server trigger asked for arrives.
        guard let amount = converted ?? nil else {
            chargedAmountText = ""
            conversionRateDate = nil
            return
        }
        chargedAmountText = AmountFormatter.editableString(amount, minorUnit: account.currencyInfo.minorUnit)
        conversionRateDate = occurredAt
    }
}

extension TransactionFormView {
    /// Splits the two fields into what the row stores, applying the sign
    /// once, from the kind the user picked — the same single point every
    /// write here has always signed at.
    ///
    /// Returns `nil` having set `errorMessage` when the entry is foreign
    /// and the charge is missing, which happens when no rate resolved and
    /// the user has not typed one: there is no number that belongs in the
    /// account's currency, and inventing one is the thing this whole
    /// workstream exists to stop.
    func resolveLedgerAmounts(magnitude: Int64) -> LedgerAmounts? {
        let signedPaid = kind == .expense ? -magnitude : magnitude
        guard isForeign, let code = paidCurrencyCode else {
            return LedgerAmounts(signedAmountE4: signedPaid, original: nil)
        }
        guard let charged = AmountParser.parse(chargedAmountText), charged > 0 else {
            errorMessage = "Enter the amount charged to \(fromAccount?.name ?? "this account")."
            return nil
        }
        return LedgerAmounts(
            signedAmountE4: kind == .expense ? -charged : charged,
            original: ForeignOriginal(amountE4: signedPaid, currency: code)
        )
    }
}
