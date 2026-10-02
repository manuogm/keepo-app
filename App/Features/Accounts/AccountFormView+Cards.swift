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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("Linked Cards")
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    Button {
                        isShowingCardHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(AppTheme.Typography.label)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityLabel("What are linked cards?")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppTheme.Spacing.m) {
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
                            addCard(to: accountId)
                        } label: {
                            CreditCardTile.addPlaceholder
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityLabel("Map a new card to this account")
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.vertical, AppTheme.Spacing.xs)
                }
                // Negative inset so the strip bleeds to the screen edges
                // while the rest of the form stays inset — a scrolling row
                // that stops short of the edge reads as if it has ended.
                .padding(.horizontal, -20)
            }
            .padding(.vertical, AppTheme.Spacing.s)
        }
    }

    /// Capture setup comes first. A card linked by hand on a phone with no
    /// Wallet automation never captures a single purchase, and the user
    /// reads that as Keepo not working. The reverse order needs no help: with
    /// capture running, the first tap-payment links its own card.
    ///
    /// Only *adding* is gated. Opening a card that is already linked —
    /// to rename or remove it — has nothing to do with whether capture runs.
    func addCard(to accountId: UUID) {
        if AppSettings.isCaptureSetUp {
            editingCard = MappedCardEditor(accountId: accountId, existing: nil)
        } else {
            isSettingUpCapture = true
        }
    }

    /// The setup sheet's `onDismiss`: carries on to the card they came here
    /// to add, but only if setup actually finished — closing it halfway
    /// leaves them on the form, exactly where they were.
    func resumeAddingCardAfterSetup() {
        guard AppSettings.isCaptureSetUp, case .edit(let accountId) = mode else { return }
        editingCard = MappedCardEditor(accountId: accountId, existing: nil)
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
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(face.secondaryForeground)
                Spacer()
                if source == .automatic {
                    AutomaticMarker(tint: face.secondaryForeground)
                }
            }
            Spacer()
            Text(name)
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(face.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(AppTheme.Spacing.m)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(face.gradient, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .overlay { face.sheen.clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card)) }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                .strokeBorder(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong), lineWidth: 1)
        }
        .elevation(.resting)
    }

    /// The empty state, kept as the strip's last item rather than shown only
    /// when there are no cards — an account can have more than one card
    /// mapped, so "none yet" is never the only moment this is useful.
    static var addPlaceholder: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card)
            .strokeBorder(AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: size.width, height: size.height)
            .overlay {
                Image(systemName: "plus")
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
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
        KeepoIcon(name: "icon-robot", size: AppTheme.Size.glyphNano)
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
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    Text(
                        "After linking a card to an account, Keepo can automatically log every payment you do "
                            + "using your iPhone"
                    )
                    .font(AppTheme.Typography.body)

                    point(
                        icon: "icon-card",
                        title: "Manual link",
                        detail: "Add the card name exactly as it appears in Apple Pay"
                    )
                    point(
                        icon: "icon-robot",
                        title: "Automatically link",
                        detail: "After a purchase using a new card, choose the account you want to link "
                            + "and Keepo will do the rest"
                    )

                    Text(
                        "Removing a linked card does not delete any past transaction, but will prevent you from "
                            + "automatically logging future ones using that card"
                    )
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .padding(AppTheme.Spacing.l)
            }
            .navigationTitle("Linked Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A glyph, like every other sheet's confirm in the app.
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            KeepoIcon(name: icon)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title).font(AppTheme.Typography.labelEmphasis)
                Text(detail).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }
}
