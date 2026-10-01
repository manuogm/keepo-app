import KeepoCore
import SwiftUI

/// My Profile → Data & Privacy → Data → Archived — archived accounts live
/// here instead of inline on `AccountsListView`, which only shows the
/// "Archived (N)" link into this screen. Unarchive is a plain, unconfirmed
/// toggle (same `archive_account` RPC, `archived: false`); delete is a
/// separate, destructive, non-reversible action behind its own confirmation.
struct ArchiveAccountsView: View {
    let session: SessionStore

    @State private var accounts: [LocalAccountRow] = []
    @State private var isLoading = true
    @State private var actionErrorMessage: String?
    @State private var deleteCandidate: DeleteCandidate?
    @State private var isDeleting = false

    /// An account the user has asked to delete, paired with how much history
    /// goes with it.
    ///
    /// The count is read *before* the alert is raised, not discovered from a
    /// failed delete. `delete_account` refuses an account that still has
    /// transactions, and that refusal used to be the whole interaction: the
    /// user got a sentence with a raw UUID in it telling them to archive an
    /// account they had already archived, and no way forward. Knowing the
    /// number up front is what lets the alert ask the real question instead.
    ///
    /// `keptTransfers` are the transfers whose other half is on a live
    /// account: those stay (migration 20261007100000), so the money they
    /// moved is still in that account's history. They are counted apart so
    /// the alert does not promise to delete what it will keep.
    private struct DeleteCandidate: Identifiable {
        let account: LocalAccountRow
        let transactionCount: Int
        let keptTransfers: Int

        var id: UUID { account.id }
        var cascades: Bool { transactionCount > 0 }
        var deletedCount: Int { transactionCount - keptTransfers }
    }

    private var archived: [LocalAccountRow] {
        accounts.filter { $0.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if archived.isEmpty {
                Text("No archived accounts")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            } else {
                List {
                    ForEach(archived) { row in
                        archiveRow(row)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let actionErrorMessage {
                VStack {
                    Spacer()
                    Text(actionErrorMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .padding()
                }
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.refresh.token) { await load() }
        // `item:` rather than `isPresented:` — the alert's own text depends on
        // the candidate, and a boolean plus a separate optional is how a
        // dialog ends up rendering one account's name over another
        // account's count for a frame.
        .alert(item: $deleteCandidate) { candidate in
            if candidate.cascades {
                Alert(
                    title: Text(
                        candidate.deletedCount > 0
                            ? "Delete \"\(candidate.account.name)\" and its \(countPhrase(candidate))?"
                            : "Delete \"\(candidate.account.name)\"?"
                    ),
                    message: Text(cascadeMessage(candidate)),
                    // Not "Everything" when transfers stay behind: the
                    // button must not promise more than the delete does.
                    primaryButton: .destructive(Text(candidate.keptTransfers > 0 ? "Delete" : "Delete Everything")) {
                        Task { await performDelete(candidate) }
                    },
                    // Named for what it leaves behind, not for the button
                    // it is. "Cancel" beside "Delete Everything" reads as
                    // "did nothing"; the account does stay, and it stays
                    // archived — which is the choice, not the absence of
                    // one.
                    secondaryButton: .cancel(Text("Keep Archived"))
                )
            } else {
                Alert(
                    title: Text("Delete \"\(candidate.account.name)\"?"),
                    message: Text("This permanently deletes the account. This cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        Task { await performDelete(candidate) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    /// "3 transactions" / "1 transaction" — the count and its noun, so the
    /// title never reads "its 1 transactions".
    private func countPhrase(_ candidate: DeleteCandidate) -> String {
        let count = candidate.deletedCount
        return "\(count) transaction\(count == 1 ? "" : "s")"
    }

    /// What goes, what stops, and — when there are any — which transfers
    /// stay behind in the other accounts' history.
    private func cascadeMessage(_ candidate: DeleteCandidate) -> String {
        let kept = candidate.keptTransfers
        guard kept > 0 else {
            return "The account and every transaction on it will be permanently deleted, "
                + "and any recurring transactions set up on it will stop. This cannot be undone."
        }
        let whatGoes = candidate.deletedCount > 0 ? "The account and its other transactions" : "The account"
        let transfers = kept == 1
            ? "Its transfer to another account stays in that account's history."
            : "Its \(kept) transfers to other accounts stay in those accounts' history."
        return "\(whatGoes) will be permanently deleted, and any recurring transactions set up on it will stop. "
            + "\(transfers) This cannot be undone."
    }

    private func archiveRow(_ row: LocalAccountRow) -> some View {
        HStack {
            CategoryIconView(icon: row.icon, color: Color(hex: row.color), diameter: AppTheme.Size.icon)
            Text(row.name).foregroundStyle(AppTheme.Palette.textSecondary)
            Spacer()
            Button {
                Task { await unarchive(row) }
            } label: {
                Text("Unarchive")
            }
            .buttonStyle(.borderless)
            Button {
                Task { await confirmDelete(row) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(AppTheme.Palette.statusNegative)
            }
            .buttonStyle(.borderless)
            .disabled(isDeleting)
        }
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

    private func unarchive(_ row: LocalAccountRow) async {
        actionErrorMessage = nil
        let payload = ArchiveAccountPayload(id: row.id, expectedVersion: row.version, archived: false)
        await session.outbox.submitArchiveAccount(payload)
        session.refresh.bump()
    }

    /// Counts the account's history, then raises the alert that matches it.
    ///
    /// The read is local, off the mirror the rest of this screen is drawn
    /// from, so it costs nothing and works offline. It can be stale — a
    /// household partner could have filed something against a shared
    /// account since the last pull — which is why the server still refuses
    /// a non-cascading delete rather than trusting this number.
    private func confirmDelete(_ row: LocalAccountRow) async {
        actionErrorMessage = nil
        let counts = (try? await session.dbQueue.read { database in
            (
                try LocalTableQueries.transactionCount(database, accountId: row.id.uuidString),
                try LocalTableQueries.transfersKeptOnDelete(database, accountId: row.id.uuidString)
            )
        }) ?? (0, 0)
        deleteCandidate = DeleteCandidate(account: row, transactionCount: counts.0, keptTransfers: counts.1)
    }

    /// Online-only, like `CategoryFormView.performDelete` — `delete_account`
    /// resolves a version race and, without `cascade`, refuses an account
    /// that still has transactions. Neither is a question that can be
    /// answered honestly from a local mirror.
    private func performDelete(_ candidate: DeleteCandidate) async {
        let row = candidate.account
        isDeleting = true
        actionErrorMessage = nil
        do {
            let succeeded = try await AccountRepository.delete(
                client: session.client, id: row.id, expectedVersion: row.version,
                cascade: candidate.cascades
            )
            if succeeded {
                try? await session.dbQueue.write { database in
                    try AccountLocalWrite.delete(
                        accountId: row.id, cascade: candidate.cascades, in: database
                    )
                }
                session.refresh.bump()
            } else {
                actionErrorMessage = "This account changed elsewhere — refresh and try again."
            }
        } catch {
            actionErrorMessage = UserFacingError.describe(error)
        }
        isDeleting = false
    }
}
