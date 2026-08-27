import KeepoCore
import SwiftUI

/// Currency Exposure's expanded half — one tile per currency, each openable
/// into the accounts inside it.
///
/// Split from `CurrencyExposureWidget.swift` for file length (SwiftLint's
/// `file_length`), and along the seam that was already there: the collapsed
/// tile is a single figure with a bar under it, this is a list. The two share
/// only the widget's data and its formatting helpers.
extension CurrencyExposureWidget {
    // MARK: - Expanded

    /// One tile per currency, scrolling. Net-short currencies sit under a
    /// divider at the end — they are real positions and omitting them would be
    /// lying by selection, but they cannot be a share of anything, so they do
    /// not belong in the same run as the currencies that can.
    func expanded(_ metrics: CurrencyExposureMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(metrics.positiveSlices.enumerated()), id: \.element.id) { rank, slice in
                    currencyTile(slice, metrics: metrics, rank: rank)
                }
                if !metrics.netShortSlices.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Net short")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                    ForEach(metrics.netShortSlices) { slice in
                        // Rank means nothing for a currency outside the ramp;
                        // it draws no bar anyway.
                        currencyTile(slice, metrics: metrics, rank: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    func currencyTile(
        _ slice: CurrencyExposureLocal, metrics: CurrencyExposureMetrics, rank: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            currencyHeader(slice, metrics: metrics, rank: rank)
            if openCurrencies.contains(slice.currency) {
                accountList(slice)
            }
        }
    }

    /// Badge, bar, figures, share, chevron — one line.
    ///
    /// The bar used to sit on its own line beneath this row, which made a
    /// currency two lines tall and put the bar closer to the *next*
    /// currency's badge than to its own. Inline, it starts where the badge
    /// ends and finishes where the figures begin, so the row reads left to
    /// right as "this currency, this much of the total, this much money".
    func currencyHeader(
        _ slice: CurrencyExposureLocal, metrics: CurrencyExposureMetrics, rank: Int
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                if openCurrencies.contains(slice.currency) {
                    openCurrencies.remove(slice.currency)
                } else {
                    openCurrencies.insert(slice.currency)
                }
            }
        } label: {
            HStack(spacing: 8) {
                CurrencyBadge(code: slice.currency, diameter: 26)
                bar(slice, metrics: metrics, rank: rank)
                amounts(slice.nativeAmountE4, converted: slice.amountBaseE4, in: slice.currencyInfo)
                Text(shareLabel(metrics.share(of: slice)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(openCurrencies.contains(slice.currency) ? 90 : 0))
            }
            // Opens the accounts inside this currency — HIG's 44pt minimum.
            .frame(minHeight: WidgetStyle.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .accessibilityLabel("\(slice.currency), \(exactLabel(slice.nativeAmountE4, in: slice.currencyInfo))")
        .accessibilityHint(openCurrencies.contains(slice.currency) ? "Hide accounts" : "Show accounts")
    }

    /// **The bar answers a different question depending on whether the row is
    /// open**, and that is the whole design of this list. The denominator
    /// changes with it, which is the part that has to stay in step with the
    /// percentage printed beside it.
    ///
    /// Closed, the currency is one thing among several: the bar is its share
    /// of everything held — the same 74% the header states — in its rank's
    /// shade of the ramp, which is also the shade of its band in the
    /// collapsed tile. So the rows are comparable down the list, and someone
    /// who opened the widget from that tile can find the band they tapped.
    ///
    /// Opened, the question stops being "how does this currency compare" and
    /// becomes "what is inside it". The bar fills the track and subdivides by
    /// account, in the colours the user picked — matching the per-account
    /// percentages in the list below, which are shares of *this currency*.
    /// Growing to full track on open is the mode change made visible.
    ///
    /// A net-short currency gets no bar and yields its width to the figures:
    /// the bar means "this is what the total is made of", and a negative
    /// total isn't made of anything you could stack. Those rows are the
    /// reason this is a `Spacer` rather than an empty branch — without one,
    /// their amounts would slide left and stop lining up with everyone
    /// else's.
    @ViewBuilder
    func bar(
        _ slice: CurrencyExposureLocal, metrics: CurrencyExposureMetrics, rank: Int
    ) -> some View {
        if slice.amountBaseE4 <= 0 {
            Spacer(minLength: 4)
        } else if openCurrencies.contains(slice.currency) {
            WidgetFillBar(segments: accountSegments(slice), thickness: 8)
        } else {
            WidgetFillBar(
                share: metrics.share(of: slice), color: WidgetPalette.shade(rank: rank), thickness: 8
            )
        }
    }

    /// The accounts inside a currency, in the colours the user picked for
    /// them, scaled against what the currency actually holds.
    func accountSegments(_ slice: CurrencyExposureLocal) -> [FillSegment] {
        let total = slice.positiveTotalE4
        guard total > 0 else { return [] }
        return slice.positiveAccounts.map { account in
            FillSegment(
                id: account.accountId,
                share: Double(account.amountBaseE4) / Double(total),
                color: Color(hex: account.color)
            )
        }
    }

    func accountList(_ slice: CurrencyExposureLocal) -> some View {
        VStack(spacing: 0) {
            ForEach(slice.accounts) { account in
                accountRow(account, in: slice)
                if account.id != slice.accounts.last?.id {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.leading, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The investment badge sits **under** the name rather than beside it.
    /// Next to it, it competed with the name for a width the row does not
    /// have and pushed long account names into an ellipsis; under it, the
    /// name keeps the whole line and the badge reads as what it is — a
    /// property of the account, not part of its title.
    ///
    /// A negative balance is drawn in the dashboard's expense colour. Its
    /// share is already "—", because a debt is not a slice of the holdings it
    /// offsets — the colour is what stops that dash reading as missing data
    /// rather than as a card.
    func accountRow(_ account: CurrencyAccountLocal, in slice: CurrencyExposureLocal) -> some View {
        HStack(spacing: 12) {
            CategoryIconView(icon: account.icon, color: Color(hex: account.color), diameter: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if account.kind == .investment {
                    InvestmentBadge()
                }
            }
            Spacer(minLength: 4)
            amounts(
                account.nativeAmountE4, converted: account.amountBaseE4, in: account.currencyInfo,
                // Always drawn, even when it is "—". A row that simply
                // omitted its share would read as a rendering slip; the dash
                // is the statement that a debt has no share of the holdings
                // it offsets.
                share: shareLabel(share(of: account, in: slice))
            )
        }
        .padding(.vertical, 8)
    }

    /// **The money the user recognises leads; the money that makes it
    /// comparable follows.**
    ///
    /// This widget is the one place on the dashboard where that order is
    /// inverted, and deliberately: everywhere else a figure is already in the
    /// base currency and there is nothing to invert. Here the whole subject
    /// is that the money *isn't* — a row headed by "€11,090" under a USD flag
    /// is a conversion pretending to be a balance, and the user's own answer
    /// to "how much is in there" is the dollar figure their bank shows.
    ///
    /// The converted figure stays, one size down, because every **share** in
    /// this widget is taken against it (see the guide note). Dropping it
    /// would leave the percentages with no visible denominator.
    ///
    /// Both are `compact` — "$49.1K" rather than "$49,127.40". Two money
    /// figures, a percentage and a bar have to share one row, and the exact
    /// cents are a line item's business, not a currency total's. VoiceOver
    /// reads the full figure (`exactLabel`), so nothing is actually lost.
    ///
    /// A slice already in the base currency shows one figure, not the same
    /// number twice: printing it twice would imply a conversion happened.
    ///
    /// `share` is already formatted, and `nil` means **no share belongs
    /// here** rather than "this share is unknown" — the currency headers have
    /// a share column of their own, while an account row always states one
    /// even if that is a dash.
    func amounts(
        _ nativeE4: Int64, converted convertedE4: Int64, in native: CurrencyInfo, share: String? = nil
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            PrivateText(MoneyFormatter.compact(nativeE4, currency: native))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(nativeE4 < 0 ? CashflowPalette.expense : Color.primary)
            HStack(spacing: 4) {
                if let share {
                    Text(share)
                }
                if let converted = convertedLabel(convertedE4, from: native) {
                    if share != nil { Text("·") }
                    PrivateText(converted)
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(Color.secondary)
        }
        .lineLimit(1)
    }

    /// What the account contributes to its currency, 0–1. `nil` for a
    /// negative account and when nothing is held — money rule 5's shape
    /// applied to a ratio, so the row renders "—" rather than a 0% that
    /// looks computed.
    ///
    /// The denominator is the currency's **positive** total, not its net:
    /// €1,000 of savings against a −€900 card nets €100, and calling the
    /// savings account "1,000% of EUR" would be arithmetically true and
    /// useless.
    func share(of account: CurrencyAccountLocal, in slice: CurrencyExposureLocal) -> Double? {
        guard account.amountBaseE4 > 0, slice.positiveTotalE4 > 0 else { return nil }
        return Double(account.amountBaseE4) / Double(slice.positiveTotalE4)
    }
}
