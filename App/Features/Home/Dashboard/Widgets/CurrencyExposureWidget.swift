import KeepoCore
import SwiftUI

/// Currency Exposure — 2×1 collapsed, 4×2 expanded.
///
/// Collapsed: which currency most of the money sits in, how much of it, and a
/// bar showing the rest of the split. Expanded: every currency as its own
/// tile, each one openable into the accounts that make it up — drawn in the
/// colours the user picked for those accounts, so a row is recognisable
/// before its name is read.
///
/// The donut this widget used to be is gone deliberately. A donut answers
/// "what share", and only that; the tile answers "what share, how much, and
/// which accounts", which is the question someone holding four currencies
/// actually has. Cashflow keeps its donut, where a category split genuinely is
/// the whole question.
struct CurrencyExposureWidget: View {
    let metrics: CurrencyExposureMetrics?
    let currency: CurrencyInfo?
    let isExpanded: Bool
    let onTap: () -> Void

    /// Which currency tiles are open. Reset on collapse, like every other
    /// widget's transient state — a widget always opens in a known state.
    @State private var openCurrencies: Set<String> = []

    var body: some View {
        WidgetChrome(
            title: DashboardWidgetKind.currencyExposure.title,
            systemImage: DashboardWidgetKind.currencyExposure.systemImage,
            onTap: onTap
        ) {
            content
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { openCurrencies = [] }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let metrics, metrics.slices == nil {
            // Distinct from "no accounts": we know there is money, we just
            // can't price it. Saying so beats a breakdown drawn from a partial
            // denominator, where every share would be wrong (money rule 5).
            WidgetEmptyState(
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                message: "Exchange rates are still catching up."
            )
        } else if let metrics, !(metrics.slices ?? []).isEmpty {
            if isExpanded {
                expanded(metrics)
            } else {
                collapsed(metrics)
            }
        } else {
            WidgetEmptyState(
                systemImage: "banknote",
                message: "No balances to break down yet."
            )
        }
    }

    // MARK: - Collapsed

    /// The dominant currency as the subject, the rest as a bar and a caption.
    ///
    /// A 2×1 tile is a square about 130pt wide inside its padding, which is
    /// three short rows at most. Listing every currency in it would either
    /// truncate at an arbitrary number or shrink the type past reading size,
    /// so one figure leads and the bar carries the shape of the remainder —
    /// the expanded tile is where the full list lives.
    private func collapsed(_ metrics: CurrencyExposureMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CurrencyBadge(code: metrics.largest?.currency, diameter: 22)
            MetricHeadline(value: .percent(metrics.largestShare), size: 30)
            Spacer(minLength: 0)
            WidgetFillBar(segments: shareSegments(metrics), thickness: 8)
            Text(remainderCaption(metrics))
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Every held currency as one stacked bar. Net-short currencies are absent
    /// rather than drawn as an outline here: at this size the bar is a shape,
    /// not a legend, and a dashed sliver a few points wide reads as a
    /// rendering artefact.
    private func shareSegments(_ metrics: CurrencyExposureMetrics) -> [FillSegment] {
        metrics.positiveSlices.compactMap { slice in
            guard let share = metrics.share(of: slice) else { return nil }
            return FillSegment(id: slice.currency, share: share, color: CurrencyColor.color(for: slice.currency))
        }
    }

    /// "EUR 28% · GBP 10%", or how many more there are when they won't fit.
    private func remainderCaption(_ metrics: CurrencyExposureMetrics) -> String {
        let rest = metrics.positiveSlices.dropFirst()
        guard !rest.isEmpty else { return "All in one currency" }
        if rest.count > 2 {
            return "+\(rest.count) more currencies"
        }
        return rest
            .map { "\($0.currency) \(shareLabel(metrics.share(of: $0)))" }
            .joined(separator: " · ")
    }

    // MARK: - Expanded

    /// One tile per currency, scrolling. Net-short currencies sit under a
    /// divider at the end — they are real positions and omitting them would be
    /// lying by selection, but they cannot be a share of anything, so they do
    /// not belong in the same run as the currencies that can.
    private func expanded(_ metrics: CurrencyExposureMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(metrics.positiveSlices) { slice in
                    currencyTile(slice, metrics: metrics)
                }
                if !metrics.netShortSlices.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Net short")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                    ForEach(metrics.netShortSlices) { slice in
                        currencyTile(slice, metrics: metrics)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func currencyTile(_ slice: CurrencyExposureLocal, metrics: CurrencyExposureMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            currencyHeader(slice, metrics: metrics)
            // A net-short currency gets no bar: the bar means "this is what
            // the total is made of", and a negative total isn't made of
            // anything you could stack.
            if slice.amountBaseE4 > 0 {
                bars(slice)
            }
            if openCurrencies.contains(slice.currency) {
                accountList(slice)
            }
        }
    }

    private func currencyHeader(_ slice: CurrencyExposureLocal, metrics: CurrencyExposureMetrics) -> some View {
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
                CurrencyBadge(code: slice.currency, diameter: 24)
                Spacer(minLength: 4)
                Text(amountLabel(slice.amountBaseE4))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text(shareLabel(metrics.share(of: slice)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
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
        .accessibilityLabel("\(slice.currency), \(amountLabel(slice.amountBaseE4))")
        .accessibilityHint(openCurrencies.contains(slice.currency) ? "Hide accounts" : "Show accounts")
    }

    /// What is held, and — separately — what is owed against it.
    ///
    /// The accounts the user is long in fill the track exactly, because they
    /// *are* the total. A credit card therefore has no room left inside the
    /// bar, and putting one there anyway would either overflow it or shrink
    /// every share below the percentage stated beside it. That is what
    /// "outlined, never stacked" protects against.
    ///
    /// Drawn as a **labelled swatch** rather than as a second scaled bar. A
    /// card offsetting 2% of a currency's holdings renders as a three-point
    /// dash — too short to show a dash pattern at all, so it reads as a
    /// rendering fault rather than as a debt. A swatch is legible at any
    /// magnitude, and the figure beside it says what the length couldn't.
    @ViewBuilder
    private func bars(_ slice: CurrencyExposureLocal) -> some View {
        let owed = slice.accounts.filter { $0.amountBaseE4 < 0 }
        VStack(alignment: .leading, spacing: 4) {
            WidgetFillBar(segments: accountSegments(slice), thickness: 8)
            if !owed.isEmpty {
                owedCaption(owed)
            }
        }
    }

    private func owedCaption(_ owed: [CurrencyAccountLocal]) -> some View {
        HStack(spacing: 5) {
            // The dash pattern comes from `WidgetFillBar` rather than being
            // redrawn here, so "outlined means owed" looks the same wherever
            // it appears.
            WidgetFillBar(
                segments: [FillSegment(
                    id: "owed",
                    share: 1,
                    color: owed.count == 1 ? Color(hex: owed[0].color) : Color.secondary,
                    isNegative: true
                )],
                thickness: 8,
                showsTrack: false
            )
            .frame(width: 24)
            Text(owedLabel(owed))
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func owedLabel(_ owed: [CurrencyAccountLocal]) -> String {
        let total = owed.reduce(0) { $0 + abs($1.amountBaseE4) }
        let amount = amountLabel(total)
        return owed.count == 1 ? "\(amount) owed on \(owed[0].name)" : "\(amount) owed on \(owed.count) accounts"
    }

    /// The accounts inside a currency, in the colours the user picked for
    /// them, scaled against what the currency actually holds.
    private func accountSegments(_ slice: CurrencyExposureLocal) -> [FillSegment] {
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

    private func accountList(_ slice: CurrencyExposureLocal) -> some View {
        VStack(spacing: 0) {
            ForEach(slice.accounts) { account in
                accountRow(account, in: slice)
                if account.id != slice.accounts.last?.id {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .padding(.leading, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func accountRow(_ account: CurrencyAccountLocal, in slice: CurrencyExposureLocal) -> some View {
        HStack(spacing: 10) {
            CategoryIconView(icon: account.icon, color: Color(hex: account.color), diameter: 24)
            Text(account.name)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(amountLabel(account.amountBaseE4))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text(contributionLabel(account, in: slice))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    /// What the account contributes to its currency, plus its own native
    /// figure when that is a different number worth seeing. A negative
    /// account has no contribution — money rule 5's shape again.
    private func contributionLabel(_ account: CurrencyAccountLocal, in slice: CurrencyExposureLocal) -> String {
        let native = account.currencyInfo.code == currency?.code
            ? nil
            : MoneyFormatter.format(account.nativeAmountE4, currency: account.currencyInfo)
        let share: String
        if account.amountBaseE4 > 0, slice.positiveTotalE4 > 0 {
            share = (Double(account.amountBaseE4) / Double(slice.positiveTotalE4))
                .formatted(.percent.precision(.fractionLength(0)))
        } else {
            share = "—"
        }
        return native.map { "\(share) · \($0)" } ?? share
    }

    // MARK: - Formatting

    /// Money rule 5's shape, applied to a ratio: an unresolvable share is
    /// "—", never 0%.
    private func shareLabel(_ share: Double?) -> String {
        guard let share else { return "—" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    private func amountLabel(_ amountE4: Int64?) -> String {
        guard let currency else { return "—" }
        return MoneyFormatter.format(amountE4, currency: currency)
    }
}
