import KeepoCore
import SwiftUI

/// UI labels are "Everyday" and "Investments" — `valuation` never appears in
/// the interface, per keepo-v1-feature-spec.md §Accounts & Multi-Currency.
struct AccountsListView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.AccountsWithBalancesSelect>(cacheKey: "accounts_with_balances")
    @State private var isAddingAccount = false
    @State private var editingAccountId: UUID?
    @State private var showConflictAlert = false
    @State private var actionErrorMessage: String?

    private var accounts: [PublicSchema.AccountsWithBalancesSelect] { store.items }

    private var everyday: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.kind == .ledger && $0.archivedAt == nil }
    }

    private var investments: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.kind == .valuation && $0.archivedAt == nil }
    }

    private var archived: [PublicSchema.AccountsWithBalancesSelect] {
        accounts.filter { $0.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                List {
                    if let asOf = store.asOf {
                        Text("Showing data as of \(asOf.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(Color("TextSecondary"))
                    }
                    if !everyday.isEmpty {
                        Section {
                            ForEach(everyday, id: \.accountId) { account in
                                accountRow(account)
                            }
                        } header: {
                            sectionHeader("Everyday", accounts: everyday)
                        }
                    }
                    if !investments.isEmpty {
                        Section {
                            ForEach(investments, id: \.accountId) { account in
                                accountRow(account)
                            }
                        } header: {
                            sectionHeader("Investments", accounts: investments)
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived") {
                            ForEach(archived, id: \.accountId) { account in
                                accountRow(account)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage ?? actionErrorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingAccount = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountFormView(session: session) {
                session.refresh.bump()
            }
        }
        .sheet(item: $editingAccountId.map(EditingAccountId.init)) { wrapped in
            AccountFormView(session: session, mode: .edit(wrapped.id)) {
                session.refresh.bump()
            }
        }
        .alert("This account changed elsewhere", isPresented: $showConflictAlert) {
            Button("OK") {}
        } message: {
            Text("The list has been refreshed with the latest version.")
        }
        .task { store.restore(from: session.payloadCache) }
        .task(id: session.refresh.token) { await load() }
    }

    @ViewBuilder
    private func accountRow(_ account: PublicSchema.AccountsWithBalancesSelect) -> some View {
        AccountRow(account: account)
            .contentShape(Rectangle())
            .onTapGesture { editingAccountId = account.accountId }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await setArchived(account, archived: account.archivedAt == nil) }
                } label: {
                    if account.archivedAt == nil {
                        Label("Archive", systemImage: "archivebox")
                    } else {
                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                    }
                }
            }
    }

    private func sectionHeader(_ title: String, accounts: [PublicSchema.AccountsWithBalancesSelect]) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(subtotalText(for: accounts))
        }
    }

    /// A subtotal only means anything converted into one common currency —
    /// each account keeps its own native currency. Renders "—" (money rule
    /// 5), never a partial sum, the moment any account in the section has a
    /// missing rate: a subtotal that silently excluded one account's
    /// balance would look like a real total while quietly being wrong.
    private func subtotalText(for accounts: [PublicSchema.AccountsWithBalancesSelect]) -> String {
        guard
            let baseCurrency = accounts.first?.baseCurrency,
            let baseMinorUnit = accounts.first?.baseMinorUnit
        else { return "—" }

        let hasMissingRate = accounts.contains { ($0.hasMissingRate ?? false) || $0.balanceBase == nil }
        let total: Decimal? = hasMissingRate ? nil : accounts.reduce(Decimal(0)) { $0 + ($1.balanceBase ?? 0) }
        return MoneyFormatter.format(total, currency: CurrencyInfo(code: baseCurrency, minorUnit: Int(baseMinorUnit)))
    }

    private func load() async {
        await store.load(
            { try await AccountRepository.fetchAllWithBalances(client: session.client) },
            cache: session.payloadCache
        )
    }

    private func setArchived(_ account: PublicSchema.AccountsWithBalancesSelect, archived: Bool) async {
        guard let id = account.accountId, let version = account.version else { return }
        actionErrorMessage = nil
        do {
            let result = try await AccountRepository.setArchived(
                client: session.client, id: id, expectedVersion: Int(version), archived: archived
            )
            session.refresh.bump()
            if case .conflict = result { showConflictAlert = true }
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
    }
}

/// `.sheet(item:)` needs an `Identifiable`; a bare `UUID?` binding isn't
/// one, and wrapping it locally is simpler than making `UUID` itself
/// Identifiable app-wide for one call site.
private struct EditingAccountId: Identifiable {
    let id: UUID
}

private extension Binding where Value == UUID? {
    func map(_ transform: @escaping (UUID) -> EditingAccountId) -> Binding<EditingAccountId?> {
        Binding<EditingAccountId?>(
            get: { wrappedValue.map(transform) },
            set: { wrappedValue = $0?.id }
        )
    }
}

private struct AccountRow: View {
    let account: PublicSchema.AccountsWithBalancesSelect

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(account.name ?? "—")
                    .foregroundStyle(account.archivedAt == nil ? Color("TextPrimary") : Color("TextSecondary"))
                // Shared/private indicator (Phase 7) — a household member
                // never has to guess whether an account is visible to their
                // partner; this reads accounts_with_balances.is_shared
                // directly rather than a second round trip per screen.
                if account.isShared == true {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color("TextSecondary"))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Balance and currency both come from the row — MoneyFormatter
                // is the one place amounts render, per CLAUDE.md's Engineering
                // Principles. A nil balance (e.g. an unsnapshotted valuation
                // account) renders as "—", never "0" (money rule 5).
                Text(formattedBalance)
                    .monospacedDigit()
                    .foregroundStyle(Color("BrandPrimary"))
                CurrencyConversionLabel(
                    nativeCurrency: account.currency,
                    amountBase: account.balanceBase,
                    baseCurrency: account.baseCurrency,
                    baseMinorUnit: account.baseMinorUnit,
                    hasMissingRate: account.hasMissingRate ?? false
                )
            }
        }
    }

    private var formattedBalance: String {
        guard let currencyCode = account.currency, let minorUnit = account.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(account.balance, currency: currency)
    }
}
