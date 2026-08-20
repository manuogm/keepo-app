import KeepoCore
import SwiftUI

/// The mapped-card popup: one card, floating over a dimmed curtain, with
/// exactly four things on it — the name, where the mapping came from, Save,
/// and Delete.
///
/// This replaces three screens (`MappedCardsView`'s pushed list,
/// `AddCardMappingSheet`, and `CardMappingDetailSheet`) that between them
/// asked the user to navigate two levels deep to rename one string. Adding
/// and editing are the same sheet here because they were always the same
/// operation — `map_card` is an upsert keyed by `(owner, card_identifier)`.
///
/// Presented with a clear background over a curtain rather than as a normal
/// sheet: a form sheet sliding up would put a card-shaped thing at the
/// bottom of the screen, and the point of the card metaphor is that it is
/// the thing you are holding.
struct MappedCardSheet: View {
    let session: SessionStore
    let editor: MappedCardEditor
    /// The account's colour, so the popup wears the same face as the tile the
    /// user tapped — without it the card appears to change identity on the
    /// way in.
    let accountColor: Color
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardName = ""
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var isNew: Bool { editor.existing == nil }

    /// Keyed on the *saved* identifier, not what is being typed — otherwise
    /// the card would shift colour on every keystroke.
    private var face: CreditCardFace {
        CreditCardFace(accountColor: accountColor, cardIdentifier: editor.existing?.cardIdentifier ?? "")
    }

    private var isSaveDisabled: Bool {
        isSaving || cardName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            // Translucent, not a solid scrim: the screen behind stays legible
            // as context, so the popup reads as something laid on top of the
            // account you are editing rather than a new place you navigated
            // to. The thin material also stops a flat black field competing
            // with the card's own colour.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.12))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 14) {
                card
                actions
            }
            .padding(.horizontal, 28)
            // Pushed up a little from true centre: dead-centre puts the name
            // field right where the keyboard's top edge lands for a new card.
            .offset(y: -30)
        }
        .presentationBackground(.clear)
        .alert("Remove this mapping?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A future Apple Pay purchase on this card will need to be reviewed and mapped again.")
        }
        .task {
            cardName = editor.existing?.cardIdentifier ?? ""
            // A brand-new card has exactly one thing to do, so it starts
            // with the keyboard already up rather than making the user tap
            // a field whose only purpose is to be typed in.
            if isNew { isNameFocused = true }
        }
    }

    /// Sized to a real payment card's proportions (ISO/IEC ID-1 is 1.586:1)
    /// with the name sitting low, the way an embossed name does. A fixed
    /// aspect ratio rather than a min-height: the resemblance is the whole
    /// affordance, and a box that grows to fill the sheet is just a sheet.
    /// The actions live below it for the same reason — buttons inside would
    /// have forced the card to a shape no card has.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "wave.3.right")
                .foregroundStyle(face.secondaryForeground)

            Spacer(minLength: 0)

            TextField("", text: $cardName, prompt: Text("Card Name").foregroundColor(face.secondaryForeground))
                .font(.title2.weight(.semibold))
                .foregroundStyle(face.foreground)
                .tint(face.foreground)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }

            provenanceLine
                .padding(.top, 6)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.top, 6)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(1.586, contentMode: .fit)
        .background(face.gradient, in: RoundedRectangle(cornerRadius: 22))
        .overlay { face.sheen.clipShape(RoundedRectangle(cornerRadius: 22)) }
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
    }

    /// Non-editable, small, and in the card's own ink — a fact about the
    /// mapping, not a field. A card the capture pipeline linked on the
    /// user's behalf says so with a chip glyph, because "why does my app
    /// know about this card?" is worth answering before it is asked.
    @ViewBuilder
    private var provenanceLine: some View {
        if let existing = editor.existing {
            HStack(spacing: 5) {
                if existing.source == .automatic {
                    AutomaticMarker(tint: face.secondaryForeground)
                }
                Text("\(existing.source == .automatic ? "Automatically" : "Manually") mapped on \(mappedOn(existing))")
            }
            .font(.caption)
            .foregroundStyle(face.secondaryForeground)
        } else {
            Text("Charges on this card will be routed to this account.")
                .font(.caption)
                .foregroundStyle(face.secondaryForeground)
        }
    }

    /// Side by side, destructive on the left. Stacked, the red button sat
    /// directly under where the thumb rests after Save — one row puts
    /// deliberate horizontal distance between "keep this" and "lose it".
    private var actions: some View {
        HStack(spacing: 12) {
            if !isNew {
                DestructiveActionButton(title: "Delete", isEnabled: !isSaving) {
                    showDeleteConfirm = true
                }
            }

            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").font(.body.weight(.semibold))
                    }
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressableCard)
            .disabled(isSaveDisabled)
            .opacity(isSaveDisabled ? 0.4 : 1)
        }
    }

    private func mappedOn(_ mapping: PublicSchema.CardMappingsSelect) -> String {
        guard let date = PostgresDate.date(fromTimestamp: mapping.createdAt) else { return "an earlier date" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// One RPC for both cases. A new card is `map_card` (an upsert, so it is
    /// also the "this card already existed elsewhere" path); a rename is
    /// `rename_card_mapping`, which resolves by natural key rather than row
    /// id — see `RenameCardMappingPayload`'s own header comment.
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        guard let ownerId = session.profile?.id else {
            errorMessage = "Your profile hasn't finished loading yet — try again in a moment."
            return
        }
        let trimmed = cardName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a card name."
            return
        }

        if let existing = editor.existing {
            guard existing.cardIdentifier != trimmed else {
                dismiss()
                return
            }
            await session.outbox.submitRenameCardMapping(
                RenameCardMappingPayload(
                    id: UUID(), ownerId: ownerId, oldCardIdentifier: existing.cardIdentifier,
                    newCardIdentifier: trimmed
                )
            )
        } else {
            await session.outbox.submitMapCard(
                MapCardPayload(
                    id: UUID(), ownerId: ownerId, cardIdentifier: trimmed, accountId: editor.accountId
                )
            )
        }
        onChanged()
        dismiss()
    }

    private func remove() async {
        guard let existing = editor.existing, let ownerId = session.profile?.id else { return }
        isSaving = true
        defer { isSaving = false }
        await session.outbox.submitUnmapCard(
            UnmapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: existing.cardIdentifier)
        )
        onChanged()
        dismiss()
    }
}
