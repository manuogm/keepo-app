import KeepoCore
import SwiftUI

/// The two filters that are **always** on show — which account, and which
/// window of time — pinned to the canvas between the banner and the ledger.
///
/// They were briefly drawn on the banner's own panel with the rest of the
/// filters, and being hidden behind the funnel before that is what made them
/// wrong to hide: between them they decide nearly everything about the list,
/// and a user looking at an unexpectedly short month had no way to see why
/// without opening a menu first. The account also carries a figure — the
/// balance — which is a fact about the account rather than a control, and a
/// fact cannot live in a drop-down.
///
/// **On the canvas rather than on the header.** A saturated brand colour is
/// the right surface for a title and a couple of glyphs; it is the wrong one
/// for a full-width row carrying a balance, which is the same object the
/// Accounts tab draws on a white card. Down here the controls can be the
/// app's own — `AccountRowView` for the account, `WidgetSegment` for the
/// period — instead of white-on-translucent-white copies of them, and the
/// header goes back to being a header.
extension TransactionsListView {
    /// Account over period: the order of a heading and its subheading, which
    /// is what these two are — "whose money", then "when".
    var filterBar: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            accountRow
            periodTrack
            periodStepper
        }
    }

    // MARK: - Account

    /// The full width of the row, and **two controls inside it**: the row
    /// opens the account itself, the chevron changes which one the ledger is
    /// showing.
    ///
    /// Splitting them is what lets the balance be tappable at all. A row that
    /// only ever opened a picker would put the account's own settings two
    /// screens away (Accounts tab → row) from the place its balance is being
    /// read, and one that only opened the editor would leave the filter with
    /// no affordance whatsoever. They are one card because they are one
    /// subject, and two buttons because they are two verbs — each with its
    /// own 44pt reach and its own accessibility label.
    ///
    /// With no account chosen there is nothing to edit, so the row opens the
    /// picker too: a control that does nothing when tapped is worse than one
    /// that does the obvious thing.
    var accountRow: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Button {
                if let accountId = filter.accountId {
                    editingAccountId = accountId
                } else {
                    isAccountPickerPresented = true
                }
            } label: {
                accountRowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableRow)
            .accessibilityLabel(
                filter.accountId == nil ? "Choose account" : "Edit \(selectedAccountName)"
            )

            Button {
                isAccountPickerPresented = true
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableRow)
            .accessibilityLabel("Change account")
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background { rowSurface }
        .animation(AppTheme.Motion.colorSafe, value: filter.accountId)
    }

    /// **The row that names the filter looks filtered** — narrowed to one
    /// account, the card is outlined in that account's own colour; at rest it
    /// is the plain surface every other card in the app is.
    ///
    /// **An outline and no fill.** A wash of the colour was tried first and
    /// works in light mode, but at 15% over a dark surface a saturated hue
    /// desaturates toward brown, and the card read as muddy rather than
    /// active — the border was doing most of the signalling anyway. Alone, it
    /// is the same colour at full strength: what "the same colour as the
    /// account" actually means, and `Checkbox` already draws its on-state
    /// exactly this way (full-strength stroke, 1.5pt). The surface underneath
    /// never changes, so the row keeps its weight whatever is selected.
    ///
    /// What this deliberately is *not* is a tinted canvas. Colour on this
    /// screen already means **scope** — the banner directly above is
    /// `scope.tint`, and the whole swipe-deck teaches that — so a second
    /// colour language spread across the page underneath it would put two
    /// meanings in one channel, with a user-chosen hue free to collide with a
    /// fixed one. Kept to a line around the row, the colour stays attached to
    /// the object it belongs to and cannot compete with the category discs
    /// and ledger-green figures in the list, which is where the eye is going.
    private var rowSurface: some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.card)
        return shape
            .fill(AppTheme.Palette.bgSurface)
            .overlay(shape.strokeBorder(selectedAccountTint ?? .clear, lineWidth: 1.5))
    }

    /// The selected account's own colour, or `nil` for "All accounts" — which
    /// has no colour of its own and must not borrow one.
    private var selectedAccountTint: Color? {
        selectedAccount.map { Color(hex: $0.color) }
    }

    /// `AccountRowView`, the row the Accounts tab is made of — icon, name,
    /// shared and card markers, balance and its base-currency conversion. The
    /// same component rather than a second arrangement of the same facts, so
    /// an account looks like itself wherever it appears and its balance is
    /// computed in one place.
    @ViewBuilder
    private var accountRowContent: some View {
        if let selected = selectedAccount {
            AccountRowView(row: selected)
        } else {
            AllAccountsRowView(balance: allAccountsBalance)
        }
    }

    var selectedAccount: LocalAccountRow? {
        filter.accountId.flatMap { id in filterAccounts.first { $0.id == id } }
    }

    /// "All accounts" is the honest name for no filter here, unlike the
    /// drop-down's pills — this row is never not on screen, so it cannot name
    /// its axis and leave the answer implied.
    var selectedAccountName: String {
        guard filter.accountId != nil else { return "All accounts" }
        return selectedAccount?.name ?? "Account"
    }

    /// What an empty ledger says — **naming the account when one is chosen**,
    /// because this is the moment the question "why is there nothing here?"
    /// is actually being asked, and an empty screen is the one state where
    /// the row above has nothing under it to corroborate what it says.
    ///
    /// It names only the account, not every filter in play. The account is
    /// the axis that is always on screen; a sentence listing the category and
    /// the type and who added it would be reciting controls the user can see,
    /// and would be wrong the moment one more axis is added.
    var emptyLedgerMessage: String {
        guard filter.accountId != nil else { return "No transactions in this period" }
        return "No transactions in \(selectedAccountName) this period"
    }

    // MARK: - Period

    /// `WidgetSegment` on the dashboard's own track — the same control the
    /// expanded widgets' W/M/Y is, because it answers the same question. It
    /// could not be that control while these filters were drawn on the
    /// banner: the selected segment punches back to **the card's own colour**
    /// to read as raised, which needs a neutral surface underneath, and a
    /// saturated scope colour is not one. On the canvas it is, so the
    /// hand-rolled white-on-colour copy is gone.
    var periodTrack: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases, id: \.self) { option in
                WidgetSegment(isSelected: period == option) {
                    periodBinding.wrappedValue = option
                } label: {
                    Text(option.rawValue)
                        // Equal shares of the row, so the five options read
                        // as one control rather than as five words.
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .font(AppTheme.Typography.micro)
        .widgetHeaderTrack()
        .animation(AppTheme.Motion.quick, value: period)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: period)
    }

    var periodStepper: some View {
        HStack {
            if period == .custom {
                Button {
                    isCustomRangePresented = true
                } label: {
                    Text(rangeLabel)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                stepButton("chevron.left", by: -1)
                Spacer()
                Text(rangeLabel)
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Spacer()
                stepButton("chevron.right", by: 1)
            }
        }
    }

    private func stepButton(_ systemName: String, by direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: systemName)
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheets

extension TransactionsListView {
    /// Every sheet the filter controls open, attached in one place.
    ///
    /// Here rather than in `body` for the same file-length reason the rest of
    /// this screen is split up — and because they belong with the controls
    /// that open them: four presentations in `body` would put the account
    /// picker three screens away from the chevron that shows it.
    var ledgerWithFilterSheets: some View {
        listContent
            .sheet(isPresented: $isAccountPickerPresented) {
                AccountFilterSheet(
                    selection: $filter.accountId, accounts: filterAccounts,
                    allAccountsBalance: allAccountsBalance
                )
            }
            // The account itself, opened from the row — the same form the
            // Accounts tab edits a row with, so nothing about editing an
            // account is defined twice. It refuses a partner's account on its
            // own (`AccountFormView.isOwner`), which is why the row offers it
            // for every account the viewer can see.
            .sheet(item: $editingAccountId) { id in
                AccountFormView(session: session, mode: .edit(id)) {
                    session.refresh.bump()
                }
            }
            .sheet(item: $activeFilterSheet) { sheet in
                filterSheet(sheet)
            }
    }

    @ViewBuilder
    private func filterSheet(_ sheet: TransactionFilterSheet) -> some View {
        switch sheet {
        case .categories:
            CategoryFilterSheet(categories: filterCategories, selection: filter.categoryIds) {
                filter.categoryIds = $0
            }
        case .kinds:
            FilterOptionsSheet(
                title: "Type", allTitle: "All types", options: Self.kindOptions, selection: filter.kinds
            ) {
                filter.kinds = $0
            }
        case .sources:
            FilterOptionsSheet(
                title: "Source", allTitle: "Any source",
                options: availableSources.map {
                    FilterOptionsSheet.Option(id: $0, title: Self.sourceTitle($0), icon: Self.sourceIcon($0))
                },
                selection: filter.sources
            ) {
                filter.sources = $0
            }
        case .authors:
            FilterOptionsSheet(
                title: "Added by", allTitle: "Anyone",
                options: authors.map { FilterOptionsSheet.Option(id: $0.id, title: $0.name) },
                selection: filter.createdByIds
            ) {
                filter.createdByIds = $0
            }
        }
    }
}

/// What the "All accounts" row shows for money, as one value: the figure and
/// the currency it is expressed in.
///
/// The two travel together because summing several accounts into one figure
/// is exactly what conversion is for, so the answer can only be in the
/// viewer's base currency — and a bare `Int64` would leave the formatter to
/// guess, which is how yen grows cents. A single account needs none of this:
/// its balance and its currency are already on its own `LocalAccountRow`.
struct AccountFilterBalance: Equatable {
    /// `nil` is "cannot be computed" — an unresolvable rate somewhere in the
    /// sum — never zero.
    let amountE4: Int64?
    let currency: CurrencyInfo
}
