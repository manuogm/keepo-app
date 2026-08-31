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
            withAnimation(.snappy(duration: 0.28)) {
                isFiltersExpanded.toggle()
                if !isFiltersExpanded { isSearching = false }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(isFiltersExpanded ? 0.28 : 0), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilter {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
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
        VStack(spacing: 10) {
            if isSearching {
                searchField
            } else {
                HStack(spacing: 8) {
                    // Three menus and a button do not fit one 402pt row at
                    // any font this panel should be using, and an account
                    // called "Joint Current Account" makes it worse. The
                    // pills scroll; the search button stays put, because a
                    // control you have to scroll to find is not a control.
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 34, height: 30)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            periodTrack
            periodStepper
        }
        .animation(.snappy(duration: 0.22), value: isSearching)
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
    }

    private var selectedCategoryName: String {
        guard let categoryId = filter.categoryId else { return "Categories" }
        return filterCategories.first { $0.id == categoryId }?.name ?? "Categories"
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
    }

    /// All three menus wear the same pill, so "which account", "which
    /// category" and "which type" read as three of one thing rather than
    /// three designs.
    ///
    /// A pill that is **doing** something goes solid white with the panel's
    /// own colour for its label — the same treatment the selected period
    /// segment gets, and the reason a filter can't quietly be on while the
    /// panel is shut. Unset, it names the axis rather than saying "All
    /// Accounts": shorter, so all three fit a phone's width without the
    /// last one being sliced by the scroll edge, and no less clear next to
    /// a chevron.
    private func pillLabel(_ title: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isActive ? session.scope.panelTint : Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.white : Color.white.opacity(0.18), in: Capsule())
    }

    private var selectedAccountName: String {
        guard let accountId = filter.accountId else { return "Accounts" }
        return filterAccounts.first { $0.id == accountId }?.name ?? "Accounts"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                Text(filter.search.map { _ in "" } ?? "")
                    .hidden()
                    .frame(width: 0)
                TextField(
                    "",
                    text: searchBinding,
                    prompt: Text("Merchant, category, or account").foregroundColor(.white.opacity(0.6))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            }
            .foregroundStyle(Color.white)
            .tint(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.18), in: Capsule())

            Button("Cancel") {
                filter.search = nil
                isSearching = false
            }
            .font(.subheadline)
            .foregroundStyle(Color.white)
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
                        .font(.caption)
                        .fontWeight(isSelected ? .bold : .regular)
                        .foregroundStyle(isSelected ? session.scope.panelTint : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
        .animation(.snappy(duration: 0.2), value: period)
        .sensoryFeedback(.selection, trigger: period)
    }

    private var periodStepper: some View {
        HStack {
            if period == .custom {
                Button {
                    isCustomRangePresented = true
                } label: {
                    Text(rangeLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                stepButton("chevron.left", by: -1)
                Spacer()
                Text(rangeLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white)
                Spacer()
                stepButton("chevron.right", by: 1)
            }
        }
        .padding(.top, 2)
    }

    private func stepButton(_ systemName: String, by direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }
}
