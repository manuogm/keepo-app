import KeepoCore
import SwiftUI

/// UI labels are "Everyday" and "Investments" — `valuation` never appears in
/// the interface, per keepo-v1-feature-spec.md §Accounts & Multi-Currency.
///
/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache, no pending-write overlay. `Outbox`'s optimistic
/// write-through means an offline (or just-submitted online) edit is
/// already in the same tables this screen queries.
struct AccountsListView: View {
    let session: SessionStore

    @State private var accounts: [LocalAccountRow] = []
    @State private var isLoading = true
    @State private var isAddingAccount = false
    @State private var editingAccountId: UUID?
    @State private var showConflictAlert = false
    @State private var actionErrorMessage: String?

    private var everyday: [LocalAccountRow] {
        accounts.filter { $0.kind == .ledger && $0.archivedAt == nil }
    }

    private var investments: [LocalAccountRow] {
        accounts.filter { $0.kind == .valuation && $0.archivedAt == nil }
    }

    private var archived: [LocalAccountRow] {
        accounts.filter { $0.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                List {
                    if !everyday.isEmpty {
                        Section {
                            ForEach(everyday) { accountRow($0) }
                        } header: {
                            sectionHeader("Everyday", accounts: everyday)
                        }
                    }
                    if !investments.isEmpty {
                        Section {
                            ForEach(investments) { accountRow($0) }
                        } header: {
                            sectionHeader("Investments", accounts: investments)
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived") {
                            ForEach(archived) { accountRow($0) }
                        }
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
        .task(id: session.refresh.token) { await load() }
    }

    @ViewBuilder
    private func accountRow(_ row: LocalAccountRow) -> some View {
        AccountRow(row: row)
            .contentShape(Rectangle())
            .onTapGesture { editingAccountId = row.id }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await setArchived(row, archived: row.archivedAt == nil) }
                } label: {
                    if row.archivedAt == nil {
                        Label("Archive", systemImage: "archivebox")
                    } else {
                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                    }
                }
            }
    }

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private func sectionHeader(_ title: String, accounts: [LocalAccountRow]) -> some View {
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
    private func subtotalText(for accounts: [LocalAccountRow]) -> String {
        guard let baseCurrency = accounts.first?.baseCurrencyInfo else { return "—" }
        let hasMissingRate = accounts.contains { $0.balanceBaseE4 == nil }
        let total: Int64? = hasMissingRate ? nil : accounts.reduce(Int64(0)) { $0 + ($1.balanceBaseE4 ?? 0) }
        return MoneyFormatter.format(total, currency: baseCurrency)
    }

    private func load() async {
        isLoading = true
        actionErrorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let dbQueue = session.dbQueue
        do {
            accounts = try await dbQueue.read { database in
                try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency)
            }
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func setArchived(_ row: LocalAccountRow, archived: Bool) async {
        actionErrorMessage = nil
        do {
            let result = try await AccountRepository.setArchived(
                client: session.client, id: row.id, expectedVersion: row.version, archived: archived
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
    let row: LocalAccountRow

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(row.name)
                    .foregroundStyle(row.archivedAt == nil ? Color.primary : Color.secondary)
                if row.isShared {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
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
                        nativeCurrency: row.currency, amountBase: row.balanceBaseE4,
                        baseCurrency: row.baseCurrencyInfo?.code,
                        baseMinorUnit: row.baseCurrencyInfo.map { Int16($0.minorUnit) },
                        hasMissingRate: row.balanceE4 != nil && row.balanceBaseE4 == nil
                    )
                }
            }
        }
    }

    private var formattedBalance: String {
        MoneyFormatter.format(row.balanceE4, currency: row.currencyInfo)
    }
}
