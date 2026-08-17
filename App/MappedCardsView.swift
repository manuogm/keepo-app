import KeepoCore
import SwiftUI

/// Pushed from the Account edit sheet's "Mapped Cards" row — lists every
/// card currently routed to this account and lets the user add, rename, or
/// remove one manually. `card_mappings` has no uniqueness on `account_id`
/// (only on `(owner_id, card_identifier)`), so an account can have more than
/// one card mapped — a list, not a single field.
struct MappedCardsView: View {
    let session: SessionStore
    let accountId: UUID
    let onChanged: () -> Void

    @State private var mappings: [PublicSchema.CardMappingsSelect] = []
    @State private var editingCardMappingId: UUID?
    @State private var showAddCard = false

    var body: some View {
        List {
            if mappings.isEmpty {
                Section {
                    Text("No cards mapped")
                        .foregroundStyle(Color.secondary)
                }
            } else {
                Section {
                    ForEach(mappings, id: \.id) { mapping in
                        Button {
                            editingCardMappingId = mapping.id
                        } label: {
                            HStack {
                                Text(mapping.cardIdentifier)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
            }

            // Always available, empty state or not — an account can have
            // more than one card mapped, so "no cards yet" is never the
            // only moment this is useful.
            Section {
                Button {
                    showAddCard = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Mapped Cards")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editingCardMappingId) { id in
            CardMappingDetailSheet(session: session, cardMappingId: id) {
                Task { await load() }
                onChanged()
            }
        }
        .sheet(isPresented: $showAddCard) {
            AddCardMappingSheet(session: session, accountId: accountId) {
                Task { await load() }
                onChanged()
            }
        }
    }

    private func load() async {
        guard let ownerId = session.profile?.id else { return }
        mappings = (try? await session.dbQueue.read { database in
            try LocalTableQueries.cardMappings(database, accountId: accountId.uuidString, ownerId: ownerId.uuidString)
        }) ?? []
    }
}

/// Manually routes a card identifier (free text, same convention
/// `capture_transaction` already stores it under) to this account — the
/// same `map_card` RPC an `ambiguous_card` Needs Review item resolves
/// through, just with the account fixed instead of picked from a list.
private struct AddCardMappingSheet: View {
    let session: SessionStore
    let accountId: UUID
    let onMapped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardIdentifier = ""
    @State private var isSaving = false

    private var isSaveDisabled: Bool {
        isSaving || cardIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("e.g. Revolut", text: $cardIdentifier)
                }
            }
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { Image(systemName: "checkmark") }
                        .disabled(isSaveDisabled)
                }
            }
        }
    }

    private func save() async {
        guard let ownerId = session.profile?.id else { return }
        let trimmed = cardIdentifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        let payload = MapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: trimmed, accountId: accountId)
        await session.outbox.submitMapCard(payload)
        onMapped()
        dismiss()
    }
}
