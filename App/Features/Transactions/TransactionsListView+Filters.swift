import KeepoCore
import SwiftUI

/// What the funnel hides: category, type, who added it, and search.
///
/// The two filters that are **not** here — which account and which period —
/// are pinned to the canvas underneath (`filterBar`), because between them
/// they decide most of what the list holds. What is left collapses behind the
/// funnel, which carries a dot when any of it is doing something: the one
/// case where hiding a control could otherwise hide the reason the list looks
/// wrong.
///
/// **One row, and that is a constraint rather than an outcome.** The panel
/// opens over the ledger and costs it that height for as long as it is open,
/// on the screen whose whole job is the list underneath. So the pills scroll
/// rather than wrap, and search and clear are glyphs on the same line rather
/// than a second row of their own.
///
/// Everything is white-on-translucent-white because the surface it sits on is
/// a saturated brand colour and changes with the scope; a control that picked
/// its own background would have to know which of the three it was on. The
/// sheets these pills open are the exception, and deliberately so — a sheet is
/// its own surface (see `TransactionFilterSheets.swift`).
extension TransactionsListView {
    /// The funnel, for the banner's accessory slot.
    var filterToggle: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) {
                isFiltersExpanded.toggle()
                if !isFiltersExpanded { isSearching = false }
            }
        } label: {
            KeepoIcon(name: isFiltersExpanded ? "icon-filter-filled" : "icon-filter", size: AppTheme.Size.glyph)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilter {
                        Circle()
                            .fill(AppTheme.Palette.textOnAccent)
                            .frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFiltersExpanded ? "Hide filters" : "Show filters")
    }

    /// True when the list on screen is a subset for a reason the funnel is
    /// **hiding**.
    ///
    /// Account and period are deliberately not counted. The dot exists to say
    /// "there is a filter you cannot see"; both of those are now permanently
    /// on screen with their own labels, so counting them would light the dot
    /// while pointing at nothing hidden — and the period, which is always set
    /// to something, would light it permanently.
    var hasActiveFilter: Bool {
        filter.categoryIds != nil || filter.kinds != nil || filter.createdByIds != nil
            || filter.sources != nil || !(filter.search?.isEmpty ?? true)
    }

    /// What the banner draws under its card — one row, whichever state it is
    /// in. Search takes the whole row when it is open: a field and three
    /// pills do not fit one phone's width, and a field the user is typing
    /// into is the only thing they are doing.
    var filterPanel: some View {
        Group {
            if isSearching {
                searchField
            } else {
                HStack(spacing: AppTheme.Spacing.s) {
                    // The pills scroll; search and clear stay put, because a
                    // control you have to scroll to find is not a control.
                    ScrollView(.horizontal) {
                        HStack(spacing: AppTheme.Spacing.s) {
                            // Every axis, always — dimmed where it cannot
                            // narrow anything yet, so the panel shows what
                            // filtering exists rather than only what applies.
                            categoryFilterPill
                            kindFilterPill
                            sourceFilterPill
                            authorFilterPill
                        }
                        // So the last pill can scroll clear of the fade
                        // instead of stopping underneath it.
                        .padding(.trailing, AppTheme.Spacing.xs)
                    }
                    .scrollIndicators(.hidden)
                    .fadingTrailingEdge()
                    // Clear **inside** search, not after it. Clear comes and
                    // goes with whether anything is set; search never does. In
                    // the other order the permanent control was the one that
                    // moved — a button jumping sideways because a different
                    // button appeared beside it — while this way the row's
                    // trailing edge is the same control however the filters
                    // stand, and the one that arrives makes room for itself.
                    if hasActiveFilter {
                        clearFiltersButton
                    }
                    searchButton
                }
            }
        }
        .animation(AppTheme.Motion.quick, value: isSearching)
    }

    // MARK: - Pills

    /// Expense / Income / Transfers. The raw values are
    /// `TransactionFilter.kinds`' own vocabulary — the same three strings the
    /// `CASE` in `LocalTransactionRow.kindExpression` derives — so nothing
    /// has to translate between this sheet and the query.
    var kindFilterPill: some View {
        pill(
            title: pillTitle(axis: "Type", count: filter.kinds?.count, single: selectedKindName),
            isActive: filter.kinds != nil
        ) {
            activeFilterSheet = .kinds
        }
    }

    private var selectedKindName: String? {
        filter.soleKind.map(Self.kindTitle)
    }

    /// The one place the three type names are spelled, shared by the pill and
    /// the sheet's own rows.
    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "income": return "Income"
        case "transfer": return "Transfers"
        default: return "Expense"
        }
    }

    static let kindOptions: [FilterOptionsSheet<String>.Option] = ["expense", "income", "transfer"].map {
        FilterOptionsSheet<String>.Option(id: $0, title: kindTitle($0))
    }

    var categoryFilterPill: some View {
        pill(
            title: pillTitle(
                axis: "Category", count: filter.categoryIds?.count,
                single: filter.soleCategoryId.flatMap { id in filterCategories.first { $0.id == id }?.name }
            ),
            isActive: filter.categoryIds != nil
        ) {
            activeFilterSheet = .categories
        }
    }

    /// How the transaction got here. Dimmed until the ledger holds more
    /// than one kind of source — an axis with a single option cannot narrow
    /// anything, and a fresh ledger is all `manual`.
    ///
    /// The captures are what this was asked for; the other sources come along
    /// because the column has them and offering only some of an enum is how a
    /// filter hides rows while looking fully open.
    var sourceFilterPill: some View {
        pill(
            title: pillTitle(
                axis: "Source", count: filter.sources?.count,
                single: filter.sources.flatMap { $0.count == 1 ? $0.first.map(Self.sourceTitle) : nil }
            ),
            isActive: filter.sources != nil,
            unavailableReason: availableSources.count > 1
                ? nil : "Available once your transactions come from more than one source"
        ) {
            activeFilterSheet = .sources
        }
    }

    /// The one place a source is named.
    ///
    /// "Automatically captured" and "Manually inputted" are spelled out rather
    /// than clipped to one word: this list is read once, when somebody is
    /// deciding what they want, not scanned repeatedly like a row's own
    /// provenance glyph — and the distinction being drawn is precisely
    /// *automatic vs by hand*, which "Captured" alone does not say to anyone
    /// who has not met the capture pipeline yet.
    ///
    /// Both are adverb-plus-participle, deliberately: two options that answer
    /// the same question should be the same shape, and "Manual input" beside
    /// "Automatically captured" read as a noun answering a verb's question.
    ///
    /// "Balance correction", not the enum's own "adjustment": the row is the
    /// gap Keepo filed when a balance was set by hand (or a transfer leg left
    /// behind by a household split), and "Adjustment" alone did not say so.
    static func sourceTitle(_ source: PublicSchema.TransactionSource) -> String {
        switch source {
        case .capture: return "Automatically captured"
        case .manual: return "Manually inputted"
        case .recurring: return "Recurring"
        case .adjustment: return "Balance correction"
        case .csvImport: return "Imported"
        }
    }

    /// **The same glyph the ledger already marks these rows with** — a
    /// captured transaction wears `icon-robot` under its title, and a
    /// recurring one the arrows, so the filter that selects them shows what
    /// the user will then see. Only the two that have a marker get one: an
    /// icon on every row would cost these two their meaning.
    static func sourceIcon(_ source: PublicSchema.TransactionSource) -> String? {
        switch source {
        case .capture: return "icon-robot"
        case .recurring: return "icon-recurrent"
        case .manual, .adjustment, .csvImport: return nil
        }
    }

    /// Dimmed until a paired household exists — see `TransactionAuthors`,
    /// which returns nothing otherwise. It filters on who **entered** the
    /// transaction, which on a joint account is the distinction a household
    /// actually wants; whose account it is is already the chip above.
    var authorFilterPill: some View {
        pill(
            title: pillTitle(
                axis: "Added by", count: filter.createdByIds?.count,
                single: filter.createdByIds.flatMap { ids in
                    ids.count == 1 ? authors.first { $0.id == ids.first }?.name : nil
                }
            ),
            isActive: filter.createdByIds != nil,
            unavailableReason: authors.isEmpty ? "Available once you share a household" : nil
        ) {
            activeFilterSheet = .authors
        }
    }

    /// One pill's label: the axis's name while unset, the single answer when
    /// there is exactly one, and **the axis plus a count** when there are
    /// several.
    ///
    /// Not "2 categories", which was the first spelling and does not fit — the
    /// chips are a fixed width at the limit of what three of them plus the
    /// search button can share on a 402pt row, and the word was sliced to "2
    /// categ…". Keeping the axis and appending the number says the same thing
    /// in the space there is, and it fails better as the text scales: a
    /// truncated "Category · 2" still reads as the category filter.
    ///
    /// Never a list of names — a pill is one line, and two names cut off at
    /// the second tells the user less than the number does.
    private func pillTitle(axis: String, count: Int?, single: String?) -> String {
        guard let count, count > 0 else { return axis }
        if count == 1, let single { return single }
        return "\(axis) · \(count)"
    }

    /// All three pills wear the same shape, so "which category", "which type"
    /// and "who added it" read as three of one thing rather than three
    /// designs.
    ///
    /// **On the two fixed widths.** These used to be `Menu`s, and a single
    /// fixed width was load-bearing for a UIKit reason: a menu shows a
    /// *snapshot* of its label while open and morphs it back into the live
    /// view on dismissal, so a label that changed width in between was scaled
    /// and sheared from a stale bitmap — a visibly torn capsule for a fraction
    /// of a second. They are plain buttons opening sheets now, so that
    /// artifact went with the menus, and the constraint could relax: a pill
    /// with an answer on it takes `answeredPillWidth`, because "Category · 2"
    /// in semibold does not fit the width "Category" needs and was arriving as
    /// "Categor…". Still two fixed widths rather than sizing to the text: a row
    /// that re-lays itself out on every pick reads as the panel twitching. The
    /// cost is that a long category name truncates, which is the trade this
    /// control was deliberately given.
    ///
    /// A pill that is **doing** something goes solid white with the panel's
    /// own colour for its label — the same treatment the selected period
    /// segment gets, and the reason a filter can't quietly be on while the
    /// panel is shut. Unset, it names the axis rather than saying "All
    /// categories": shorter, so all three fit a phone's width without the
    /// last one being sliced by the scroll edge, and no less clear next to a
    /// chevron. The axis names are **singular** for the same width reason —
    /// a uniform chip has to be as wide as its longest unset label.
    ///
    /// A non-nil `unavailableReason` draws the pill dimmed and inert, and
    /// is what VoiceOver says about it: the axis is shown so the user knows
    /// it exists, and told why it does nothing yet.
    private func pill(
        title: String, isActive: Bool, unavailableReason: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.label)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Typography.nanoEmphasis)
            }
            .foregroundStyle(isActive ? session.scope.panelTint : AppTheme.Palette.textOnAccent)
            // `.s`, not `.m`: a fixed width has to be wide enough for the
            // longest *unset* label, and three chips plus the search button
            // have one 402pt row to live on. Tighter side padding is what
            // buys that back.
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xs)
            // The width is fixed **after** the padding, so the chip is one
            // size in each of its two states and the label truncates inside
            // that rather than stretching it.
            .frame(width: isActive ? answeredPillWidth : pillWidth)
            .background(
                isActive
                    ? AppTheme.Palette.textOnAccent
                    : AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .opacity(unavailableReason == nil ? 1 : AppTheme.Opacity.muted)
        .accessibilityHint(unavailableReason ?? "")
    }

    // MARK: - Clear

    /// Clears **what the funnel hides**, and nothing else.
    ///
    /// The account and the period are two controls the user is looking at
    /// while they tap this; resetting them from a panel that does not contain
    /// either would undo a choice they can see they made.
    ///
    /// A glyph beside the search one rather than a labelled row of its own:
    /// the row it would have added is the ledger's height, and it only ever
    /// appears once something is set — which is when the pills themselves
    /// have already gone white and said so. It is also the only control here
    /// that is not on screen at rest, so its arriving is part of the signal.
    private var clearFiltersButton: some View {
        Button {
            filter.categoryIds = nil
            filter.kinds = nil
            filter.createdByIds = nil
            filter.sources = nil
            filter.search = nil
            isSearching = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear filters")
    }

}

/// Which multi-select sheet is open. One piece of state rather than three
/// booleans, so two of them can never be true at once.
enum TransactionFilterSheet: String, Identifiable {
    case categories
    case kinds
    case sources
    case authors

    var id: String { rawValue }
}
