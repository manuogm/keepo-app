import KeepoCore
import SwiftUI

/// Resolves an `ambiguous_card` Needs Review item — `item.subtitle` carries
/// the raw `card_identifier` (see migration 20260807160000's comment on why
/// it's there and not parsed out of `title`). Only ledger (spendable)
/// accounts are offered — `map_card` itself refuses anything else. Split out
/// of `NeedsReviewView.swift` purely to keep that file under the project's
/// file-length lint threshold.
struct MapCardSheet: View {
    let session: SessionStore
    let item: PublicSchema.NeedsReviewSelect
    let onMapped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [LocalAccountRow] = []
    @State private var selectedAccountId: UUID?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                if let cardIdentifier = item.subtitle {
                    Section("Card") {
                        Text(cardIdentifier)
                    }
                }
                Section("Route charges to") {
                    Picker("Account", selection: $selectedAccountId) {
                        Text("Choose an account").tag(UUID?.none)
                        ForEach(ledgerAccounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                }
            }
            .navigationTitle("Map Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await mapCard() } } label: { Image(systemName: "checkmark") }
                        .disabled(selectedAccountId == nil || isSaving)
                }
            }
            .task {
                guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
                    return
                }
                accounts = (try? await session.dbQueue.read { database in
                    try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency)
                }) ?? []
            }
        }
    }

    private var ledgerAccounts: [LocalAccountRow] {
        accounts.filter { $0.kind == .ledger && $0.archivedAt == nil }
    }

    private func mapCard() async {
        guard let selectedAccountId, let cardIdentifier = item.subtitle, let ownerId = session.profile?.id else {
            return
        }
        isSaving = true
        defer { isSaving = false }
        // Local-first, like every other write in the app — this used to
        // call `CaptureRepository.mapCard` directly against the network
        // client, which left the local `card_mappings` mirror stale: the
        // RPC succeeded, but nothing here ever re-pulled, so the item sat
        // in Needs Review looking unresolved until some unrelated sync
        // happened to catch it up (found chasing a real bug — the sheet
        // "did nothing" after mapping).
        await session.outbox.submitMapCard(
            MapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: cardIdentifier, accountId: selectedAccountId)
        )
        onMapped()
        dismiss()
    }
}
