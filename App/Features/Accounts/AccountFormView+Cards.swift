import KeepoCore
import SwiftUI

// The mapped-cards strip, split out of AccountFormView.swift purely to keep
// that file under the project's file-length lint threshold — same precedent
// as TransactionFormView+Transfer.swift.

/// What the card popup is editing. A brand-new card and an existing one are
/// the same sheet with the same shape — only the starting text and which
/// actions are offered differ — so they are one type rather than two sheets
/// that have to be kept looking identical.
struct MappedCardEditor: Identifiable {
    let accountId: UUID
    let existing: PublicSchema.CardMappingsSelect?

    var id: String { existing?.id.uuidString ?? "new-\(accountId.uuidString)" }
}

extension AccountFormView {
    /// A horizontally scrolling row of cards that look like cards, ending in
    /// a dashed "add" placeholder — kept last, always, so adding a second or
    /// third card is the same gesture as adding the first. This replaces a
    /// `NavigationLink` labelled "Mapped Cards / None", which answered the
    /// question ("how many?") but made the actual action two taps away and
    /// showed nothing about the cards themselves.
    ///
    /// Edit mode only: `card_mappings` rows key off an account id, so there
    /// is nothing to attach a card to until the account exists.
    @ViewBuilder
    var mappedCardsStrip: some View {
        if case .edit(let accountId) = mode {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Linked Cards")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                    Button {
                        isShowingCardHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityLabel("What are linked cards?")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(cardMappings, id: \.id) { mapping in
                            Button {
                                editingCard = MappedCardEditor(accountId: accountId, existing: mapping)
                            } label: {
                                CreditCardTile(
                                    name: mapping.cardIdentifier,
                                    source: mapping.source,
                                    face: CreditCardFace(
                                        accountColor: color, cardIdentifier: mapping.cardIdentifier
                                    )
                                )
                            }
                            .buttonStyle(.pressableCard)
                        }

                        Button {
                            editingCard = MappedCardEditor(accountId: accountId, existing: nil)
                        } label: {
                            CreditCardTile.addPlaceholder
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityLabel("Map a new card to this account")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                // Negative inset so the strip bleeds to the screen edges
                // while the rest of the form stays inset — a scrolling row
                // that stops short of the edge reads as if it has ended.
                .padding(.horizontal, -20)
            }
            .padding(.vertical, 8)
        }
    }

    func loadCardMappings() async {
        guard case .edit(let id) = mode, let ownerId = session.profile?.id else { return }
        cardMappings = (try? await session.dbQueue.read { database in
            try LocalTableQueries.cardMappings(database, accountId: id.uuidString, ownerId: ownerId.uuidString)
        }) ?? []
    }
}

/// One mapped card, drawn as a card. The proportions are deliberately close
/// to a real payment card (ISO/IEC 7810 ID-1 is 1.586:1) — that resemblance
/// is the whole affordance, and it is why this needs no label explaining
/// what the row is. The face comes from the account's own colour (see
/// `CreditCardFace`), so a card always looks like it belongs to the account
/// it is mapped to.
struct CreditCardTile: View {
    let name: String
    let source: PublicSchema.CardMappingSource
    let face: CreditCardFace

    static let size = CGSize(width: 176, height: 111)

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "wave.3.right")
                    .font(.caption)
                    .foregroundStyle(face.secondaryForeground)
                Spacer()
                if source == .automatic {
                    AutomaticMarker(tint: face.secondaryForeground)
                }
            }
            Spacer()
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(face.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(face.gradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay { face.sheen.clipShape(RoundedRectangle(cornerRadius: 14)) }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    /// The empty state, kept as the strip's last item rather than shown only
    /// when there are no cards — an account can have more than one card
    /// mapped, so "none yet" is never the only moment this is useful.
    static var addPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: size.width, height: size.height)
            .overlay {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.secondary)
            }
    }
}

/// The "a machine did this, not you" marker — a small chip glyph, used both
/// on a card tile and in the card popup's provenance line. Takes its tint
/// from the caller because it sits on a coloured card face in one place and
/// on a plain surface in the other.
struct AutomaticMarker: View {
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: "cpu")
            .font(.caption)
            .foregroundStyle(tint)
            .accessibilityLabel("Mapped automatically")
    }
}

/// What "linked cards" are, in the user's terms — reachable from the (?)
/// beside the strip. This is the one place in the app that explains the
/// Apple Pay capture pipeline to the person using it, so it says what they
/// get, not how it works.
struct LinkedCardsHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(
                        "When you pay with a card, Keepo can file the purchase against this account "
                            + "for you — no typing."
                    )
                    .font(.body)

                    point(
                        icon: "creditcard.fill",
                        title: "Link the cards you actually use",
                        detail: "Add the card name exactly as it appears in Apple Pay. "
                            + "Every purchase on it lands in this account."
                    )
                    point(
                        icon: "cpu",
                        title: "Some link themselves",
                        detail: "A card the capture pipeline recognised while you reviewed a purchase "
                            + "is marked with a chip icon."
                    )
                    point(
                        icon: "tray.full.fill",
                        title: "Unrecognised cards wait for you",
                        detail: "A purchase on a card Keepo does not know yet goes to Needs Review "
                            + "instead of guessing."
                    )

                    Text(
                        "Removing a link never deletes anything you have already recorded — future "
                            + "purchases on that card just need reviewing again."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Linked Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Color.secondary)
            }
        }
    }
}
