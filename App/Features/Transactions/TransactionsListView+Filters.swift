import KeepoCore
import SwiftUI

/// The filter controls, drawn **on the scope banner's own colour** rather
/// than as a toolbar underneath it.
///
/// Moving them into the header is what let the ledger start at the top of
/// the screen: an account menu, a five-way period picker, a stepper and a
/// search field is a lot of chrome to leave permanently above a list. They
/// collapse behind one funnel button, which carries a dot when any of them
/// is actually doing something — the one case where hiding a control could
/// otherwise hide the reason the list looks wrong.
///
/// Everything here is white-on-translucent-white because the surface it sits
/// on is a saturated brand colour and changes with the scope; a control that
/// picked its own background would have to know which of the three it was
/// on. Split from TransactionsListView.swift for file length.
extension TransactionsListView {
    /// The funnel, for the banner's accessory slot.
    var filterToggle: some View {
        Button {
            withAnimation(AppTheme.Motion.standard) {
                isFiltersExpanded.toggle()
                if !isFiltersExpanded { isSearching = false }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .background(AppTheme.Palette.textOnAccent.opacity(isFiltersExpanded ? 0.28 : 0), in: Circle())
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

    /// True when the list on screen is a subset for a reason the user chose
    /// — not counting the period, which is always set to something.
    var hasActiveFilter: Bool {
        filter.accountId != nil || filter.categoryId != nil || filter.kind != nil
            || !(filter.search?.isEmpty ?? true)
    }

    var filterPanel: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            if isSearching {
                searchField
            } else {
                HStack(spacing: AppTheme.Spacing.s) {
                    // Three menus and a button do not fit one 402pt row at
                    // any font this panel should be using, and an account
                    // called "Joint Current Account" makes it worse. The
                    // pills scroll; the search button stays put, because a
                    // control you have to scroll to find is not a control.
                    ScrollView(.horizontal) {
                        HStack(spacing: AppTheme.Spacing.s) {
                            accountFilterMenu
                            categoryFilterMenu
                            kindFilterMenu
                        }
                    }
                    .scrollIndicators(.hidden)
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.textOnAccent)
                            .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                            .background(
                                AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong), in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            periodTrack
            periodStepper
        }
        .animation(AppTheme.Motion.quick, value: isSearching)
    }

    /// Expense / Income / Transfers. The raw values are
    /// `TransactionFilter.kind`'s own vocabulary — the same three strings the
    /// `CASE` in `LocalTransactionRow.fetchFiltered` derives — so nothing has
    /// to translate between this menu and the query.
    var kindFilterMenu: some View {
        Menu {
            kindOption(nil, label: "All Types")
            kindOption("expense", label: "Expense")
            kindOption("income", label: "Income")
            kindOption("transfer", label: "Transfers")
        } label: {
            pillLabel(selectedKindName, isActive: filter.kind != nil)
        }
        .transaction { $0.animation = nil }
    }

    private func kindOption(_ kind: String?, label: String) -> some View {
        Button {
            filter.kind = kind
        } label: {
            if filter.kind == kind {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var selectedKindName: String {
        switch filter.kind {
        case "expense": return "Expense"
        case "income": return "Income"
        case "transfer": return "Transfers"
        default: return "Types"
        }
    }

    var categoryFilterMenu: some View {
        Menu {
            Button {
                filter.categoryId = nil
            } label: {
                if filter.categoryId == nil {
                    Label("All Categories", systemImage: "checkmark")
                } else {
                    Text("All Categories")
                }
            }
            ForEach(filterCategories, id: \.id) { category in
                Button {
                    filter.categoryId = category.id
                } label: {
                    if filter.categoryId == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            pillLabel(selectedCategoryName, isActive: filter.categoryId != nil)
        }
        .transaction { $0.animation = nil }
    }

    private var selectedCategoryName: String {
        guard let categoryId = filter.categoryId else { return "Category" }
        return filterCategories.first { $0.id == categoryId }?.name ?? "Category"
    }

    var accountFilterMenu: some View {
        Menu {
            Button {
                filter.accountId = nil
            } label: {
                if filter.accountId == nil {
                    Label("All Accounts", systemImage: "checkmark")
                } else {
                    Text("All Accounts")
                }
            }
            ForEach(filterAccounts) { account in
                Button {
                    filter.accountId = account.id
                } label: {
                    if filter.accountId == account.id {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
            }
        } label: {
            pillLabel(selectedAccountName, isActive: filter.accountId != nil)
        }
        .transaction { $0.animation = nil }
    }

    /// All three menus wear the same pill, so "which account", "which
    /// category" and "which type" read as three of one thing rather than
    /// three designs.
    ///
    /// **On the brief distortion after picking an option.** Traced frame by
    /// frame from a `simctl io recordVideo` capture, after several wrong
    /// guesses — record it again before believing any new theory about it.
    ///
    /// While a `Menu` is open, UIKit hides the real pill and shows a
    /// *snapshot* of it taken when the menu opened. On dismissal it morphs
    /// that snapshot back into the live view's frame. Picking a different
    /// option changes this label's text, so by the time the morph runs the
    /// live pill is a **different width than the snapshot** — UIKit scales
    /// and shears a stale bitmap into a frame that no longer matches it, and
    /// a capsule's rounded caps do not survive that. For ~0.15–0.3s the pill
    /// reads as a torn, square-ended blob with its text hanging off.
    ///
    /// The control experiment is what pins it: picking the option that was
    /// *already selected* dismisses through the identical animation and
    /// renders cleanly the whole way, because the snapshot and the live view
    /// still agree. The wider the new name is than the old one, the larger
    /// the mismatch and the longer it stays visible — which is why a name
    /// wider than the visible row is the worst case.
    ///
    /// The two mitigations below take it from about a second to ~0.15–0.3s.
    /// Neither removes it: the morph is UIKit's, and the mismatch it is
    /// morphing is inherent to a pill whose width depends on its selection.
    /// **The cure is a pill whose width does not change with the
    /// selection** — a fixed width with tail truncation — which is a visual
    /// decision this note deliberately does not make on its own.
    ///
    /// 1. `pillWidth` — a **fixed** width, which is what actually removes
    ///    it: the snapshot and the live view are now always the same size,
    ///    so there is no mismatch left for the morph to reveal. It is a
    ///    width and not a `minWidth` for exactly that reason — a minimum
    ///    still grows for a long name and brings the artifact back with it.
    ///    The cost is that a name wider than a chip truncates, which is the
    ///    trade this control was deliberately given.
    /// 2. `.transaction { $0.animation = nil }` on each of the three `Menu`s
    ///    — on the menu, not on this label. Picking an option re-keys
    ///    `TransactionsLoadKey`, so the reload lands in the same turn, and
    ///    the pill was being carried along by whatever animation that turn
    ///    had open. Same reason `FxRateWidget.quotePicker` does it.
    ///
    /// A pill that is **doing** something goes solid white with the panel's
    /// own colour for its label — the same treatment the selected period
    /// segment gets, and the reason a filter can't quietly be on while the
    /// panel is shut. Unset, it names the axis rather than saying "All
    /// Accounts": shorter, so all three fit a phone's width without the
    /// last one being sliced by the scroll edge, and no less clear next to
    /// a chevron.
    ///
    /// The axis names are **singular** ("Account", "Category"), which is
    /// load-bearing now rather than a style choice: a uniform chip has to be
    /// as wide as its longest unset label, and three chips plus the search
    /// button have one 402pt row to share. At "Categories" the third chip was
    /// sliced at rest — the very thing this paragraph says the short labels
    /// exist to avoid. Singular also happens to be the more accurate word:
    /// each of these filters to exactly one.
    private func pillLabel(_ title: String, isActive: Bool) -> some View {
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
        // longest *unset* label ("Categories", which must never truncate —
        // an axis name with an ellipsis reads as a bug), and three chips
        // plus the search button have one 402pt row to live on. Tighter
        // side padding is what buys that back.
        .padding(.horizontal, AppTheme.Spacing.s)
        .padding(.vertical, AppTheme.Spacing.xs)
        // The width is fixed **after** the padding, so the chip is one size
        // whatever is in it and the label truncates inside that rather than
        // stretching it. See this function's own note for why this is a
        // width and not a minimum.
        .frame(width: pillWidth)
        .background(
            isActive
                ? AppTheme.Palette.textOnAccent
                : AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong),
            in: Capsule()
        )
    }

    private var selectedAccountName: String {
        guard let accountId = filter.accountId else { return "Account" }
        return filterAccounts.first { $0.id == accountId }?.name ?? "Account"
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(AppTheme.Typography.micro)
                Text(filter.search.map { _ in "" } ?? "")
                    .hidden()
                    .frame(width: 0)
                TextField(
                    "",
                    text: searchBinding,
                    prompt: Text("Merchant, category, or account")
                        .foregroundStyle(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppTheme.Typography.label)
            }
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .tint(AppTheme.Palette.textOnAccent)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong), in: Capsule())

            Button("Cancel") {
                filter.search = nil
                isSearching = false
            }
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.textOnAccent)
        }
    }

    /// The same shape the dashboard's expanded widgets use for W/M/Y — a
    /// faint track with a hairline border around the whole set and the
    /// selected option sitting in a capsule on it (`TimeframeFilterView`'s
    /// `WidgetHeaderTrack`). The border is the point: it says these five
    /// options are one control and only one of them can be true.
    ///
    /// The palette is the on-colour counterpart rather than a shared type.
    /// The widget version punches its selected capsule back to *the card's
    /// own colour* to read as raised, which needs a neutral card underneath;
    /// here the surface is a saturated brand colour, so the selected capsule
    /// is white and takes the scope's colour for its label.
    private var periodTrack: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases, id: \.self) { option in
                let isSelected = period == option
                Button {
                    periodBinding.wrappedValue = option
                } label: {
                    Text(option.rawValue)
                        .font(AppTheme.Typography.micro)
                        .fontWeight(isSelected ? .bold : .regular)
                        .foregroundStyle(isSelected ? session.scope.panelTint : AppTheme.Palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(isSelected ? AppTheme.Palette.textOnAccent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fill), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.dim), lineWidth: 1))
        .animation(AppTheme.Motion.quick, value: period)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: period)
    }

    private var periodStepper: some View {
        HStack {
            if period == .custom {
                Button {
                    isCustomRangePresented = true
                } label: {
                    Text(rangeLabel)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                stepButton("chevron.left", by: -1)
                Spacer()
                Text(rangeLabel)
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                Spacer()
                stepButton("chevron.right", by: 1)
            }
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }

    private func stepButton(_ systemName: String, by direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: systemName)
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }
}
