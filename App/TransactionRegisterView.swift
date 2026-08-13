import KeepoCore
import SwiftUI

/// The "See All" drill-down from `TransactionsListView`'s Recent section —
/// full history for one week/month/year at a time, grouped by day. Reads
/// straight off the local GRDB mirror (Phase L6), same as the Recent
/// section itself.
struct TransactionRegisterView: View {
    let session: SessionStore

    enum Period: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"

        var component: Calendar.Component {
            switch self {
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            }
        }
    }

    @State private var period: Period = .month
    @State private var anchor = Date()
    @State private var transactions: [PublicSchema.TransactionsWithDetailsSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?

    private let calendar = Calendar.current

    private var range: DateInterval {
        calendar.dateInterval(of: period.component, for: anchor) ?? DateInterval(start: anchor, duration: 0)
    }

    private var groupedByDay: [(day: Date, items: [PublicSchema.TransactionsWithDetailsSelect])] {
        let groups = Dictionary(grouping: transactions) { transaction -> Date in
            guard
                let occurredAt = transaction.occurredAt, let date = PostgresDate.date(fromTimestamp: occurredAt)
            else { return .distantPast }
            return calendar.startOfDay(for: date)
        }
        return groups.keys.sorted(by: >).map { day in (day: day, items: groups[day] ?? []) }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                periodNavigator

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if transactions.isEmpty {
                    Spacer()
                    Text("No transactions in this period")
                        .foregroundStyle(Color.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(groupedByDay, id: \.day) { group in
                            Section {
                                ForEach(group.items, id: \.transactionId) { transaction in
                                    TransactionRow(transaction: transaction, category: category(for: transaction))
                                        .contentShape(Rectangle())
                                        .onTapGesture { editingTransaction = transaction }
                                }
                            } header: {
                                Text(group.day.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(session: session, mode: .edit(transaction, sibling: nil)) {
                session.refresh.bump()
                Task { await load() }
            }
        }
        .task(id: RegisterLoadKey(period: period, anchor: anchor)) { await load() }
    }

    private var periodNavigator: some View {
        VStack(spacing: 8) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(rangeLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
            }
        }
        .padding()
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch period {
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
        }
    }

    private func step(_ direction: Int) {
        anchor = calendar.date(byAdding: period.component, value: direction, to: anchor) ?? anchor
    }

    private func category(
        for transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.CategoriesSelect? {
        categories.first { $0.id == transaction.categoryId }
    }

    private func load() async {
        errorMessage = nil
        isLoading = true
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let filterRange = TransactionFilter(from: range.start, through: range.end)
        let dbQueue = session.dbQueue
        do {
            let (fetchedTransactions, fetchedCategories) = try await dbQueue.read { database in
                (
                    try LocalTransactionRow.fetchFiltered(
                        database, filter: filterRange, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                    ),
                    categories.isEmpty ? try LocalTableQueries.categories(database) : categories
                )
            }
            transactions = fetchedTransactions
            categories = fetchedCategories
        } catch {
            transactions = []
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}

private struct RegisterLoadKey: Equatable {
    let period: TransactionRegisterView.Period
    let anchor: Date
}
