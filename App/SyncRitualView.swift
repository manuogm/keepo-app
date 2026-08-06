import KeepoCore
import SwiftUI

/// Per-account freshness label, on-demand "Sync now," and the reconcile
/// flow — the ritual itself never stores a balance (see the migration's
/// header comment); this screen only ever reads accounts_sync_status and
/// calls the two reconcile RPCs.
struct SyncRitualView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.AccountsSyncStatusSelect>()
    @State private var reconcilingAccountId: UUID?

    private var accounts: [PublicSchema.AccountsSyncStatusSelect] {
        store.items.filter { $0.archivedAt == nil }
    }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else {
                List {
                    ForEach(accounts, id: \.accountId) { account in
                        row(account)
                            .contentShape(Rectangle())
                            .onTapGesture { reconcilingAccountId = account.accountId }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Sync Ritual")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Sync now") { Task { await load() } }
            }
        }
        .sheet(item: $reconcilingAccountId.map(ReconcilingAccountId.init)) { wrapped in
            if let account = accounts.first(where: { $0.accountId == wrapped.id }) {
                ReconcileAccountView(session: session, account: account) {
                    session.refresh.bump()
                    Task { await load() }
                }
            }
        }
        .task(id: session.refresh.token) { await load() }
    }

    private func row(_ account: PublicSchema.AccountsSyncStatusSelect) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name ?? "—")
                    .foregroundStyle(Color("TextPrimary"))
                StalenessBadge(
                    isStale: account.isStale ?? false,
                    lastVerifiedAt: account.lastVerifiedAt.flatMap { PostgresDate.date(fromTimestamp: $0) }
                )
            }
            Spacer()
            Text(formattedBalance(account))
                .monospacedDigit()
                .foregroundStyle(Color("BrandPrimary"))
        }
    }

    private func formattedBalance(_ account: PublicSchema.AccountsSyncStatusSelect) -> String {
        guard let code = account.currency, let minorUnit = account.minorUnit else { return "—" }
        return MoneyFormatter.format(account.balance, currency: CurrencyInfo(code: code, minorUnit: Int(minorUnit)))
    }

    private func load() async {
        await store.load { try await ReconciliationRepository.fetchSyncStatus(client: session.client) }
    }
}

private struct ReconcilingAccountId: Identifiable {
    let id: UUID
}

private extension Binding where Value == UUID? {
    func map(_ transform: @escaping (UUID) -> ReconcilingAccountId) -> Binding<ReconcilingAccountId?> {
        Binding<ReconcilingAccountId?>(
            get: { wrappedValue.map(transform) },
            set: { wrappedValue = $0?.id }
        )
    }
}

/// Enter balance → see the exact adjustment before committing (spec: "always
/// visible, never silently absorbed") → save. Valuation accounts skip the
/// adjustment preview entirely — no transaction review step, no adjustment,
/// ever, for that kind (spec, explicit).
private struct ReconcileAccountView: View {
    let session: SessionStore
    let account: PublicSchema.AccountsSyncStatusSelect
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var enteredText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showConflictAlert = false

    private var currency: CurrencyInfo? {
        guard let code = account.currency, let minorUnit = account.minorUnit else { return nil }
        return CurrencyInfo(code: code, minorUnit: Int(minorUnit))
    }

    private var isValuation: Bool { account.kind == .valuation }

    /// A client-side preview only — the RPC recomputes the real gap
    /// server-side at save time and is the sole source of truth for what
    /// actually posts; this just keeps the user from ever hitting "Save"
    /// on an adjustment they haven't seen.
    private var gap: Decimal? {
        guard let entered = AmountParser.parse(enteredText), let current = account.balance else { return nil }
        return entered - current
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isValuation ? "Current value" : "Enter balance") {
                    TextField("0.00", text: $enteredText)
                        .keyboardType(.decimalPad)
                }

                if !isValuation, let gap, gap != 0, let currency {
                    Section("Adjustment") {
                        HStack {
                            Text(gap > 0 ? "Income adjustment" : "Expense adjustment")
                            Spacer()
                            Text(MoneyFormatter.format(gap, currency: currency))
                                .monospacedDigit()
                                .foregroundStyle(gap > 0 ? Color("BrandPrimary") : .red)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(account.name ?? "Reconcile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(enteredText.isEmpty || isSaving)
                }
            }
            .alert("This account changed elsewhere", isPresented: $showConflictAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Someone already reconciled this account — reload and try again.")
            }
        }
        .task {
            enteredText = AmountFormatter.editableString(account.balance ?? 0, minorUnit: currency?.minorUnit ?? 2)
        }
    }

    private func save() async {
        guard let entered = AmountParser.parse(enteredText), let accountId = account.accountId else {
            errorMessage = "Enter a valid balance."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            let result: ReconciliationWriteResult = if isValuation {
                try await ReconciliationRepository.reconcileValuationAccount(
                    client: session.client,
                    accountId: accountId,
                    enteredValue: entered,
                    expectedLastReconciliationId: account.lastReconciliationId
                )
            } else {
                try await ReconciliationRepository.reconcileLedgerAccount(
                    client: session.client,
                    accountId: accountId,
                    enteredBalance: entered,
                    expectedLastReconciliationId: account.lastReconciliationId
                )
            }
            switch result {
            case .saved:
                onSaved()
                dismiss()
            case .conflict:
                showConflictAlert = true
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
