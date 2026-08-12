import KeepoCore
import SwiftUI

/// One list, reached from Settings — not a top-level tab, matching the
/// existing precedent (Household/Sync Ritual aren't tabs either). Shows
/// each rule's own `next_due_at` directly; nothing here ever queries or
/// creates a materialized row — that's `materialize_recurring`'s job alone,
/// running on its own daily cron schedule (Phase 13/14).
struct RecurringRulesView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.RecurringRulesSelect>(cacheKey: "recurring_rules")
    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var isAddingRule = false
    @State private var editingRule: PublicSchema.RecurringRulesSelect?
    @State private var actionErrorMessage: String?

    private var rules: [PublicSchema.RecurringRulesSelect] { store.items }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else if rules.isEmpty {
                Text("No recurring transactions yet")
                    .foregroundStyle(Color.secondary)
            } else {
                List {
                    ForEach(rules, id: \.id) { rule in
                        RecurringRuleRow(rule: rule, account: account(for: rule), category: category(for: rule))
                            .contentShape(Rectangle())
                            .onTapGesture { editingRule = rule }
                    }
                    .onDelete { offsets in
                        Task { await pause(at: offsets) }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let actionErrorMessage {
                VStack {
                    Spacer()
                    Text(actionErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Recurring")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingRule = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingRule) {
            RecurringRuleFormView(session: session) {
                session.refresh.bump()
            }
        }
        .sheet(item: $editingRule) { rule in
            RecurringRuleFormView(session: session, mode: .edit(rule)) {
                session.refresh.bump()
            }
        }
        .task { store.restore(from: session.payloadCache) }
        .task(id: session.refresh.token) { await load() }
    }

    private func account(for rule: PublicSchema.RecurringRulesSelect) -> PublicSchema.AccountsWithBalancesSelect? {
        accounts.first { $0.accountId == rule.accountId }
    }

    private func category(for rule: PublicSchema.RecurringRulesSelect) -> PublicSchema.CategoriesSelect? {
        categories.first { $0.id == rule.categoryId }
    }

    private func load() async {
        async let accountsResult = AccountRepository.fetchAllWithBalances(client: session.client)
        async let categoriesResult = CategoryRepository.fetchAll(client: session.client)
        accounts = (try? await accountsResult) ?? []
        categories = (try? await categoriesResult) ?? []
        await store.load(
            { try await RecurringRuleRepository.fetchAll(client: session.client) },
            cache: session.payloadCache
        )
    }

    /// "Delete" pauses, never removes — a recurring rule has already
    /// materialized real, historical transactions that must keep their
    /// `recurring_rule_id` pointing at something. `active = false` simply
    /// stops future materialization.
    private func pause(at offsets: IndexSet) async {
        actionErrorMessage = nil
        for index in offsets {
            let rule = rules[index]
            do {
                try await RecurringRuleRepository.setActive(client: session.client, id: rule.id, active: false)
            } catch {
                actionErrorMessage = UserFacingError.describe(error)
            }
        }
        session.refresh.bump()
    }
}

extension PublicSchema.RecurringRulesSelect: Identifiable {}

private struct RecurringRuleRow: View {
    let rule: PublicSchema.RecurringRulesSelect
    let account: PublicSchema.AccountsWithBalancesSelect?
    let category: PublicSchema.CategoriesSelect?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category?.name ?? "—")
                    .foregroundStyle(Color.primary)
                Text("\(account?.name ?? "—") · \(frequencyLabel) · next \(nextDueLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            let currencyInfo = CurrencyInfo(code: rule.currency, minorUnit: Int(account?.minorUnit ?? 2))
            Text(MoneyFormatter.format(rule.amount, currency: currencyInfo))
                .monospacedDigit()
                .foregroundStyle(rule.active ? Color.primary : Color.secondary)
            if !rule.active {
                Image(systemName: "pause.circle")
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var frequencyLabel: String {
        switch rule.frequency {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    private var nextDueLabel: String {
        guard let date = PostgresDate.dateOnly(from: rule.nextDueAt) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
