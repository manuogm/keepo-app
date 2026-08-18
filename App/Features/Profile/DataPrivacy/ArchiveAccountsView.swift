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
    @State private var deleteCandidate: LocalAccountRow?
    @State private var isDeleting = false

    private var archived: [LocalAccountRow] {
        accounts.filter { $0.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if archived.isEmpty {
                Text("No archived accounts")
                    .foregroundStyle(Color.secondary)
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
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.refresh.token) { await load() }
        .alert(
            "Delete \"\(deleteCandidate?.name ?? "")\"?",
            isPresented: deleteConfirmationBinding
        ) {
            Button("Delete", role: .destructive) {
                if let deleteCandidate { Task { await performDelete(deleteCandidate) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the account. This cannot be undone.")
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })
    }

    private func archiveRow(_ row: LocalAccountRow) -> some View {
        HStack {
            CategoryIconView(icon: row.icon, color: Color(hex: row.color), diameter: 32)
            Text(row.name).foregroundStyle(Color.secondary)
            Spacer()
            Button {
                Task { await unarchive(row) }
            } label: {
                Text("Unarchive")
            }
            .buttonStyle(.borderless)
            Button {
                deleteCandidate = row
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color.red)
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

    /// Online-only, like `CategoryFormView.performDelete` — `delete_account`
    /// refuses (raises) while the account still has non-deleted
    /// transactions, a live check that can't be answered honestly offline.
    private func performDelete(_ row: LocalAccountRow) async {
        isDeleting = true
        actionErrorMessage = nil
        do {
            let succeeded = try await AccountRepository.delete(
                client: session.client, id: row.id, expectedVersion: row.version
            )
            if succeeded {
                try? await session.dbQueue.write { database in
                    try AccountLocalWrite.delete(accountId: row.id, in: database)
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
