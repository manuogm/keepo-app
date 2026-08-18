import KeepoCore
import SwiftUI

/// The Account edit sheet's "tap a mapped card" popup — view/rename/remove
/// one `card_mappings` row. Mirrors `AccountFormView`'s own `.edit(UUID)`
/// shape: takes just the id and re-fetches from the local mirror itself,
/// rather than trusting a possibly-stale row passed in from the list that
/// opened it.
struct CardMappingDetailSheet: View {
    let session: SessionStore
    let cardMappingId: UUID
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardIdentifier = ""
    /// The identifier as loaded, before any edit — the natural key
    /// `rename`/`remove` resolve against server- and locally-side (see
    /// `RenameCardMappingPayload`'s own header comment on why this
    /// changed from the mapping's row id).
    @State private var originalCardIdentifier = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showRemoveConfirm = false
    @State private var errorMessage: String?

    private var isSaveDisabled: Bool {
        isLoading || isSaving || cardIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    Section("Card") {
                        TextField("Card name", text: $cardIdentifier)
                    }

                    Section {
                        Button("Remove Mapping", role: .destructive) {
                            showRemoveConfirm = true
                        }
                        .disabled(isSaving)
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Mapped Card")
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
            .alert("Remove this mapping?", isPresented: $showRemoveConfirm) {
                Button("Remove", role: .destructive) { Task { await remove() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A future Apple Pay purchase on this card will need to be reviewed and mapped again.")
            }
        }
        .task { await load() }
    }

    private func load() async {
        let loaded = (try? await session.dbQueue.read { database in
            try LocalTableQueries.cardMapping(database, id: cardMappingId.uuidString)
        })??.cardIdentifier ?? ""
        cardIdentifier = loaded
        originalCardIdentifier = loaded
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        guard let ownerId = session.profile?.id else {
            errorMessage = "Your profile hasn't finished loading yet — try again in a moment."
            return
        }
        await session.outbox.submitRenameCardMapping(
            RenameCardMappingPayload(
                id: UUID(), ownerId: ownerId, oldCardIdentifier: originalCardIdentifier,
                newCardIdentifier: cardIdentifier
            )
        )
        onChanged()
        dismiss()
    }

    private func remove() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        guard let ownerId = session.profile?.id else {
            errorMessage = "Your profile hasn't finished loading yet — try again in a moment."
            return
        }
        await session.outbox.submitUnmapCard(
            UnmapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: originalCardIdentifier)
        )
        onChanged()
        dismiss()
    }
}
