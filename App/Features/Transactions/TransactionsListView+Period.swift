import SwiftUI

/// The filter bar above the list — the account menu and the period navigator
/// (day/week/month/year/custom) — plus the one entry point another screen has
/// into this one. Split out of TransactionsListView.swift purely to keep that
/// file under the project's file-length/type-body-length lint thresholds.
extension TransactionsListView {
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
            HStack(spacing: 4) {
                Text(selectedAccountName)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedAccountName: String {
        guard let accountId = filter.accountId else { return "All Accounts" }
        return filterAccounts.first { $0.id == accountId }?.name ?? "All Accounts"
    }

    var periodNavigator: some View {
        VStack(spacing: 8) {
            Picker("Period", selection: periodBinding) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if period != .custom {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(rangeLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                }
            } else {
                Button {
                    isCustomRangePresented = true
                } label: {
                    Text(rangeLabel)
                        .font(.subheadline)
                }
            }
        }
        .padding()
    }

    /// Adopts a period another screen asked for — the Cashflow widget's
    /// category chevron — and clears the request.
    ///
    /// Clearing is what stops the filter reappearing every time the user
    /// comes back to this tab, long after they changed it to something else.
    func applyPendingRequest() {
        guard let navigation, let request = navigation.transactionsRequest else { return }
        filter.categoryId = request.categoryId
        filter.kind = request.kind
        period = .custom
        customFrom = request.from
        customThrough = request.through
        navigation.transactionsRequest = nil
    }

    /// Picking "Custom" opens the range sheet; *becoming* custom does not.
    ///
    /// The difference matters now that another screen can hand this one a
    /// period to show (`TransactionsRequest`), which arrives as a custom
    /// range already chosen. Watching the value with `.onChange` couldn't
    /// tell the two apart and popped the sheet over a list the user had just
    /// been sent to. A binding's setter only runs when the control writes it,
    /// which is exactly the distinction — the sheet belongs to the tap, not
    /// to the value.
    var periodBinding: Binding<Period> {
        Binding(
            get: { period },
            set: { chosen in
                period = chosen
                if chosen == .custom { isCustomRangePresented = true }
            }
        )
    }

    var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("Through", selection: $customThrough, displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { isCustomRangePresented = false } label: { Image(systemName: "checkmark") }
                }
            }
        }
    }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch period {
        case .day:
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: anchor)
        case .week:
            formatter.dateFormat = "MMM d"
            let end = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(formatter.string(from: range.start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: anchor)
        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: anchor)
        case .custom:
            formatter.dateFormat = "MMM d, yyyy"
            return "\(formatter.string(from: customFrom)) – \(formatter.string(from: customThrough))"
        }
    }

    func step(_ direction: Int) {
        guard let component = period.component else { return }
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }
}
