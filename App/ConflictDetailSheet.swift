import KeepoCore
import SwiftUI

/// E: tapping a `sync_conflict` Needs Review row used to offer nothing but
/// a swipe-to-dismiss ("Resolve", which only marks the audit row resolved
/// without telling the user what happened or letting them choose which
/// side wins). This is the modal that replaces it.
///
/// "Keep Mine" is intentionally scoped to what this app's conflicts
/// actually are: a transaction re-submits its current local edit; an
/// account re-submits its archived flag, the one account field a version
/// conflict has actually been observed to come from (a local delete/
/// unavailable row disables the option rather than guessing).
struct ConflictDetailSheet: View {
    let session: SessionStore
    let conflictId: UUID
    var onResolved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detail: SyncConflictDetail?
    @State private var summary: String?
    @State private var myAccount: PublicSchema.AccountsSelect?
    @State private var myTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canKeepMine: Bool {
        guard let detail else { return false }
        return detail.tableName == "accounts" ? myAccount != nil : myTransaction != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let detail {
                    Form {
                        Section("What changed") {
                            Text(detail.tableName == "accounts" ? "Account" : "Transaction")
                            if let summary {
                                Text(summary).foregroundStyle(.secondary)
                            } else {
                                Text("No longer available locally — pull to see the server's version.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section("Versions") {
                            LabeledContent("Your version", value: "\(detail.clientVersion)")
                            LabeledContent("Server version", value: "\(detail.serverVersion)")
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("This conflict no longer applies.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if detail != nil { actionButtons }
            }
        }
        .task { await load() }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await keepServer() }
            } label: {
                Text("Keep Server Version").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if canKeepMine {
                Button {
                    Task { await keepMine() }
                } label: {
                    Text("Keep My Version").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .padding()
    }

    /// Captures "my version" — the local mirror's current, still-optimistic
    /// field values — before either action below ever pulls, since a pull
    /// overwrites this same row with the server's authoritative one.
    private func load() async {
        guard let loaded = try? await session.dbQueue.read({ database in
            try ConflictLocalQueries.detail(database, id: conflictId.uuidString)
        }) else {
            isLoading = false
            return
        }
        detail = loaded

        if loaded.tableName == "accounts" {
            myAccount = try? await session.dbQueue.read { database in
                try LocalTableQueries.account(database, id: loaded.rowId)
            }
            summary = myAccount.map { "\($0.name) — \($0.archivedAt == nil ? "active" : "archived")" }
        } else if let baseCurrency = session.profile?.baseCurrency, let ownerId = session.profile?.id {
            myTransaction = try? await session.dbQueue.read { database in
                try LocalTransactionRow.fetchOne(
                    database, id: loaded.rowId, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }
            if let transaction = myTransaction, let amount = transaction.amountE4, let currency = transaction.currency {
                let info = CurrencyInfo(code: currency, minorUnit: Int(transaction.minorUnit ?? 2))
                let formatted = MoneyFormatter.format(amount, currency: info)
                summary = "\(transaction.merchantRaw ?? transaction.categoryName ?? "Transaction") — \(formatted)"
            }
        }
        isLoading = false
    }

    /// The pull alone already corrects the local mirror to the server's
    /// row — nothing left to do but mark the conflict resolved.
    private func keepServer() async {
        guard let detail else { return }
        isWorking = true
        errorMessage = nil
        await session.syncEngine?.pull()
        await resolve(detail)
        isWorking = false
    }

    private func keepMine() async {
        guard let detail else { return }
        isWorking = true
        errorMessage = nil
        await session.syncEngine?.pull()
        let freshVersion = await currentServerVersion(detail)
        if detail.tableName == "accounts", let myAccount {
            _ = await session.outbox.submitArchiveAccount(
                ArchiveAccountPayload(
                    id: myAccount.id, expectedVersion: freshVersion, archived: myAccount.archivedAt != nil
                )
            ).value
        } else if let myTransaction, let id = myTransaction.transactionId, let categoryId = myTransaction.categoryId {
            _ = await session.outbox.submitUpdateTransaction(
                UpdateTransactionPayload(
                    id: id, expectedVersion: freshVersion,
                    accountId: myTransaction.accountId ?? UUID(), categoryId: categoryId,
                    amountE4: myTransaction.amountE4 ?? 0, currency: myTransaction.currency ?? "USD",
                    occurredAt: PostgresDate.date(fromTimestamp: myTransaction.occurredAt ?? "") ?? Date(),
                    merchantRaw: myTransaction.merchantRaw
                )
            ).value
        }
        await resolve(detail)
        isWorking = false
    }

    /// After the pull above, the local row's own `version` IS the server's
    /// current one — no separate network round trip needed to learn it.
    private func currentServerVersion(_ detail: SyncConflictDetail) async -> Int {
        let fresh: Int? = try? await session.dbQueue.read { database in
            if detail.tableName == "accounts" {
                return try LocalTableQueries.account(database, id: detail.rowId).map { Int($0.version) }
            }
            return try LocalTableQueries.transaction(database, id: detail.rowId).map { Int($0.version) }
        }
        return fresh ?? detail.serverVersion
    }

    private func resolve(_ detail: SyncConflictDetail) async {
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: detail.id)
            session.refresh.bump()
            onResolved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}
