import KeepoCore
import SwiftUI

// The three pages, split out of ExportView.swift for the project's
// file-length and type-body-length lints — same precedent as
// TransactionFormView+Date.swift. Nothing here is `private`, for that reason.

extension ExportView {
    // MARK: - 1. Accounts

    var accountsPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            pageHeading("Which accounts?")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                CheckboxRow(title: "All accounts", isOn: isAllAccounts) {
                    selection.accountIds = isAllAccounts ? [] : Set(accounts.map(\.id))
                }
                FormCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(accounts) { account in
                            accountRow(account, isSelected: selection.accountIds.contains(account.id)) {
                                if selection.accountIds.contains(account.id) {
                                    selection.accountIds.remove(account.id)
                                } else {
                                    selection.accountIds.insert(account.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var isAllAccounts: Bool {
        !accounts.isEmpty && selection.accountIds == Set(accounts.map(\.id))
    }

    /// "All accounts", one name, "Checking and Savings", or "3 accounts" —
    /// what the recap says, and what the PDF's header says.
    var accountsLabel: String {
        if isAllAccounts { return "All accounts" }
        let chosen = accounts.filter { selection.accountIds.contains($0.id) }.map(\.name)
        switch chosen.count {
        case 0: return "No accounts"
        case 1: return chosen[0]
        case 2: return "\(chosen[0]) and \(chosen[1])"
        default: return "\(chosen.count) accounts"
        }
    }

    /// A checkbox row, the same square as All accounts above it — several of
    /// these can be on at once, which is what a square says and a radio
    /// circle would deny.
    private func accountRow(
        _ account: LocalAccountRow, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.m) {
                CategoryIconView(icon: account.icon, color: Color(hex: account.color))
                Text(account.name)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .lineLimit(1)
                Text(account.currency)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer(minLength: AppTheme.Spacing.s)
                Checkbox(isOn: isSelected)
            }
            .padding(.vertical, AppTheme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 2. Period

    /// The calendar itself, with the answers people usually give laid over
    /// it: All time, and pills that fill in a preset's days. Any two taps on
    /// the calendar are an answer too, and a pair that happens to be exactly
    /// a preset's days lights that pill (`ExportPeriod.named`).
    ///
    /// Not in a scroll view like the other pages — the calendar is one, and
    /// a scroll inside a scroll is a gesture fight.
    var periodPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("Which period?")
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.top, AppTheme.Spacing.l)
            HStack(spacing: AppTheme.Spacing.m) {
                CheckboxRow(title: "All time", isOn: range.isAllTime) { range.isAllTime.toggle() }
                MonthJumpMenu(range: range, focus: $calendarFocus)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.xl)
            quickPicks
                .padding(.vertical, AppTheme.Spacing.m)
            RangeCalendar(range: $range, focus: $calendarFocus)
        }
    }

    /// Scrolls sideways rather than wrapping: four pills do not fit across a
    /// phone, and a second row would come out of the calendar's height.
    private var quickPicks: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.s) {
                ForEach(ExportPeriod.presets, id: \.self) { preset in
                    ExportPeriodPill(title: preset.presetTitle ?? "", isSelected: selection.period == preset) {
                        pick(preset)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, AppTheme.Spacing.l, for: .scrollContent)
    }

    /// A pill fills in its days and brings the first one into view; the
    /// period itself follows from the days (`ExportView.period(for:)`), the
    /// same way it does for two taps.
    private func pick(_ preset: ExportPeriod) {
        guard let days = preset.days(now: Date(), calendar: calendar) else { return }
        range = DayRange(start: days.lowerBound, end: days.upperBound)
        calendarFocus = days.lowerBound
    }

    /// The dates the period resolves to, in words — "September 2026",
    /// "Aug 1 – Sep 23, 2026", "All time".
    var periodLabel: String? {
        selection.period?.label(now: Date(), calendar: calendar)
    }

    // MARK: - 3. Format

    /// The question, with everything already answered above it — so someone
    /// arriving pre-filled from the Transactions list sees what the file will
    /// hold before choosing how to hold it, and can go back to any of it. The
    /// formats are the Notifications screen's cards (`ChoiceCard`).
    var formatPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            pageHeading("Which format?")
            recap
            VStack(spacing: AppTheme.Spacing.l) {
                ForEach(ExportFormat.allCases) { format in
                    ChoiceCard(title: format.title, detail: format.purpose, isSelected: selection.format == format) {
                        selection.format = format
                    } icon: {
                        Image(systemName: Self.symbol(for: format))
                            .resizable()
                            .scaledToFit()
                            .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                    }
                }
            }
        }
    }

    private var recap: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(recapHeader)
                .font(AppTheme.Typography.captionEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.l)
            FormCard(padding: AppTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: 0) {
                    ExportRecapRow(title: "Accounts", value: accountsLabel) { go(to: .accounts) }
                    Divider().padding(.vertical, AppTheme.Spacing.xs)
                    ExportRecapRow(title: "Period", value: periodValue, detail: periodDetail) { go(to: .period) }
                    if selection.hasCarriedFilters {
                        Divider().padding(.vertical, AppTheme.Spacing.xs)
                        carriedFilters
                    }
                }
            }
        }
    }

    /// "124 transactions in this file" — the count is the one thing the
    /// recap adds that no earlier page could, and a zero here says why the
    /// button will not go.
    private var recapHeader: String {
        switch entryCount {
        case .none: return "In this file"
        case 0: return "No transactions match these choices"
        case let count?: return "\(count) transaction\(count == 1 ? "" : "s") in this file"
        }
    }

    /// A preset by its name, with its dates underneath; a custom range by
    /// its dates alone.
    private var periodValue: String {
        selection.period?.presetTitle ?? periodLabel ?? "—"
    }

    private var periodDetail: String? {
        guard let period = selection.period, period.presetTitle != nil, period != .allTime else { return nil }
        return periodLabel
    }

    /// The Transactions list's other filters, which the file honours too — so
    /// they are shown, and each can be dropped, rather than applied silently.
    private var carriedFilters: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text("Also filtered by")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            TagFlowLayout(spacing: AppTheme.Spacing.s) {
                if let categoryId = selection.categoryId {
                    ExportFilterChip(title: categories.first { $0.id == categoryId }?.name ?? "Category") {
                        selection.categoryId = nil
                    }
                }
                if let kind = selection.kind {
                    ExportFilterChip(title: Self.kindLabel(kind)) { selection.kind = nil }
                }
                if let search = selection.search, !search.isEmpty {
                    ExportFilterChip(title: "\u{201C}\(search)\u{201D}") { selection.search = nil }
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.s)
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "income": return "Income"
        case "transfer": return "Transfers"
        default: return "Expenses"
        }
    }

    private static func symbol(for format: ExportFormat) -> String {
        switch format {
        case .csv: return "doc.plaintext"
        case .excel: return "tablecells"
        case .pdf: return "doc.richtext"
        }
    }

    // MARK: - Shared

    /// The question, in onboarding's own heading style.
    private func pageHeading(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.Typography.screenTitle)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
