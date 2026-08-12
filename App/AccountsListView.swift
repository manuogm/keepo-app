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
    @State private var fxRates: [String: Decimal] = [:]

    private var accounts: [PublicSchema.AccountsWithBalancesSelect] { store.items }

    /// Every cached account, with its balance and base-currency conversion
    /// overlaid with whatever's still queued in the outbox — a pending
    /// expense or transfer moves this number immediately, not just once it
    /// syncs (Option 1: Postgres stays the money authority, this only ever
    /// adds deltas the server will apply too, never approximates).
    private var overlaidAccounts: [OverlaidAccount] {
        let cachedBalances = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.accountId.flatMap { id in account.balance.map { (id, $0) } }
        })
        let cachedTransactions = PendingOverlayAdapter.cachedTransactionLookup(session: session)
        let overlay = PendingOverlayAdapter.overlaidBalances(
            cached: cachedBalances, outbox: session.outbox, cachedTransactions: cachedTransactions
        )
        return accounts.map { account in
            guard
                let id = account.accountId, let overlaidBalance = overlay[id], overlaidBalance != account.balance
            else {
                return OverlaidAccount(
                    account: account, balance: account.balance, balanceBase: account.balanceBase, isPending: false
                )
            }
            let balanceBase: Decimal? = account.currency.flatMap { currency in
                account.baseCurrency.flatMap { base in
                    LocalFxConvert.convert(overlaidBalance, from: currency, to: base, rates: fxRates)
                }
            }
            return OverlaidAccount(
                account: account, balance: overlaidBalance, balanceBase: balanceBase, isPending: true
            )
        }
    }

    private var everyday: [OverlaidAccount] {
        overlaidAccounts.filter { $0.account.kind == .ledger && $0.account.archivedAt == nil }
    }

    private var investments: [OverlaidAccount] {
        overlaidAccounts.filter { $0.account.kind == .valuation && $0.account.archivedAt == nil }
    }

    private var archived: [OverlaidAccount] {
        overlaidAccounts.filter { $0.account.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                List {
                    if !everyday.isEmpty {
                        Section {
                            ForEach(everyday) { overlaid in
                                accountRow(overlaid)
                            }
                        } header: {
                            sectionHeader("Everyday", accounts: everyday)
                        }
                    }
                    if !investments.isEmpty {
                        Section {
                            ForEach(investments) { overlaid in
                                accountRow(overlaid)
                            }
                        } header: {
                            sectionHeader("Investments", accounts: investments)
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived") {
                            ForEach(archived) { overlaid in
                                accountRow(overlaid)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ScopeSwitcherButton(session: session)
            }
            ToolbarItem(placement: .principal) {
                ScreenTitleBar(title: "Accounts", session: session)
            }
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
        .task { fxRates = await FxRateCache.fetchLatestRates(session: session) }
    }

    @ViewBuilder
    private func accountRow(_ overlaid: OverlaidAccount) -> some View {
        let account = overlaid.account
        AccountRow(overlaid: overlaid)
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

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private func sectionHeader(_ title: String, accounts: [OverlaidAccount]) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(isPrivacyMode ? "••••" : subtotalText(for: accounts))
        }
    }

    /// A subtotal only means anything converted into one common currency —
    /// each account keeps its own native currency. Renders "—" (money rule
    /// 5), never a partial sum, the moment any account in the section has a
    /// missing rate: a subtotal that silently excluded one account's
    /// balance would look like a real total while quietly being wrong.
    private func subtotalText(for overlaidAccounts: [OverlaidAccount]) -> String {
        guard
            let baseCurrency = overlaidAccounts.first?.account.baseCurrency,
            let baseMinorUnit = overlaidAccounts.first?.account.baseMinorUnit
        else { return "—" }

        let hasMissingRate = overlaidAccounts.contains {
            ($0.account.hasMissingRate ?? false) || $0.balanceBase == nil
        }
        let total: Decimal? = hasMissingRate ? nil : overlaidAccounts.reduce(Decimal(0)) { $0 + ($1.balanceBase ?? 0) }
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

/// An account row's balance, overlaid with whatever's still queued in the
/// outbox — `balance`/`balanceBase` are the numbers to actually render;
/// `account`'s own `.balance`/`.balanceBase` stay untouched for identity
/// and every other field. `isPending` is true only when a pending write
/// actually changed this account's balance, not merely because something
/// is queued elsewhere.
private struct OverlaidAccount: Identifiable {
    let account: PublicSchema.AccountsWithBalancesSelect
    let balance: Decimal?
    let balanceBase: Decimal?
    let isPending: Bool
    var id: UUID { account.accountId ?? UUID() }
}

private struct AccountRow: View {
    let overlaid: OverlaidAccount

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var account: PublicSchema.AccountsWithBalancesSelect { overlaid.account }

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(account.name ?? "—")
                    .foregroundStyle(account.archivedAt == nil ? Color.primary : Color.secondary)
                // Shared/private indicator (Phase 7) — a household member
                // never has to guess whether an account is visible to their
                // partner; this reads accounts_with_balances.is_shared
                // directly rather than a second round trip per screen.
                if account.isShared == true {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if overlaid.isPending {
                    Image(systemName: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(isPrivacyMode ? "••••" : formattedBalance)
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                if !isPrivacyMode {
                    CurrencyConversionLabel(
                        nativeCurrency: account.currency,
                        amountBase: overlaid.balanceBase,
                        baseCurrency: account.baseCurrency,
                        baseMinorUnit: account.baseMinorUnit,
                        hasMissingRate: (account.hasMissingRate ?? false)
                            || (overlaid.isPending && overlaid.balanceBase == nil)
                    )
                }
            }
        }
    }

    private var formattedBalance: String {
        guard let currencyCode = account.currency, let minorUnit = account.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(overlaid.balance, currency: currency)
    }
}
