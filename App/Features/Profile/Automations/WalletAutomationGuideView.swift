import KeepoCore
import SwiftUI
import UIKit

/// Automatic capture, as a thing you have rather than a thing you read
/// about.
///
/// **Two screens in one, and which one you get is the whole design.** This
/// used to be a single page of instructions shown to everybody — the
/// walkthrough, permanently, whether or not it had already been followed.
/// For a user who had set capture up months ago that is a screen about a
/// job they finished, with nothing on it about the thing they actually came
/// to look at: which cards are linked, and where the shortcut lives.
///
/// So: someone who has not set it up gets onboarding's own pitch and one
/// button. Everyone else gets what they built — the shortcut, and their
/// linked cards — and never sees the instructions again unless they ask for
/// them.
struct WalletAutomationGuideView: View {
    let session: SessionStore

    @State private var mappedCards: [MappedCardRow] = []
    @State private var isSettingUp = false
    @State private var editingAccountId: UUID?

    /// The weaker of the two capture signals, and the right one here — see
    /// `AppSettings.captureSetupCompletedAt`. Waiting for a *real* purchase
    /// would keep showing setup instructions to somebody who had just
    /// finished setting up.
    ///
    /// **Held in `@State` and re-read, not computed.** A computed property
    /// over a `UserDefaults` static is not something SwiftUI can observe, so
    /// this screen would have kept showing the blank state after the setup
    /// sheet closed — the one moment it is guaranteed to be wrong.
    @State private var isSetUp = AppSettings.captureSetupCompletedAt != nil

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                    if isSetUp {
                        configured
                    } else {
                        blankState
                    }
                }
                .padding(AppTheme.Spacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Automatic Capture")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSettingUp) {
            CaptureSetupFlowView(session: session)
        }
        .sheet(item: $editingAccountId) { id in
            AccountFormView(session: session, mode: .edit(id)) {
                session.refresh.bump()
            }
        }
        .onChange(of: isSettingUp) { _, isPresenting in
            guard !isPresenting else { return }
            isSetUp = AppSettings.captureSetupCompletedAt != nil
        }
        .task(id: session.refresh.token) { await load() }
    }

    // MARK: - Nothing set up yet

    /// Onboarding's pitch verbatim — `CapturePitchView` — with one button
    /// instead of two. "Set up later" is what got them here; offering it
    /// again on the screen they opened *to* set it up would be a button
    /// whose only function is to undo the tap that opened the screen.
    private var blankState: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            CapturePitchView()
            OnboardingPrimaryButton(title: "Set up now", fillsWidth: true) {
                isSettingUp = true
            }
        }
    }

    // MARK: - Set up

    private var configured: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            CaptureStatusCard(session: session)
            shortcutsSection
            mappedCardsSection
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            sectionTitle("My Shortcuts")
            Button {
                openShortcuts()
            } label: {
                ShortcutCardTile(name: ShortcutsWalkthrough.shortcutName)
            }
            .buttonStyle(.pressableCard)
            .accessibilityLabel("Open \(ShortcutsWalkthrough.shortcutName) in the Shortcuts app")
        }
    }

    /// A carousel rather than a list, and the **same** `CreditCardTile` the
    /// account form draws. A card should look like the same object wherever
    /// it appears; two renderings of one card is how a user ends up unsure
    /// whether they are looking at the same thing.
    @ViewBuilder
    private var mappedCardsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            sectionTitle("My Mapped Cards")

            if mappedCards.isEmpty {
                // Expected, not an error: the automation can be wired up
                // before any purchase has taught Keepo a card, and the first
                // one arrives through Needs Review.
                Text("No cards linked yet. The first purchase Keepo captures will ask you which account "
                     + "it belongs to, and the card is linked from there.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppTheme.Spacing.m) {
                        ForEach(mappedCards) { card in
                            Button {
                                editingAccountId = card.accountId
                            } label: {
                                CreditCardTile(
                                    name: card.cardIdentifier,
                                    source: card.source,
                                    face: CreditCardFace(
                                        accountColor: Color(hex: card.accountColor),
                                        cardIdentifier: card.cardIdentifier
                                    )
                                )
                            }
                            .buttonStyle(.pressableCard)
                            .accessibilityLabel("\(card.cardIdentifier), linked to \(card.accountName)")
                            .accessibilityHint("Opens the account")
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.vertical, AppTheme.Spacing.xs)
                }
                // Negative inset so the strip bleeds to the screen edges
                // while the rest of the screen stays inset — a scrolling row
                // that stops short of the edge reads as if it has ended.
                // Matches the account form's own strip.
                .padding(.horizontal, -AppTheme.Spacing.l)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Typography.rowTitle)
            .foregroundStyle(AppTheme.Palette.textPrimary)
    }

    private func openShortcuts() {
        guard let url = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func load() async {
        isSetUp = AppSettings.captureSetupCompletedAt != nil
        guard let ownerId = session.profile?.id else { return }
        mappedCards = (try? await session.dbQueue.read { database in
            try MappedCardQueries.all(database, ownerId: ownerId.uuidString)
        }) ?? []
    }
}

/// The Keepo Capture shortcut, drawn the way Shortcuts draws it.
///
/// The resemblance is the affordance, exactly as it is for `CreditCardTile`
/// — a tile the shape and proportions of a Shortcuts card, in Keepo's
/// colour, carrying the shortcut's real name. It says "this object lives in
/// that app" without a line of text explaining that it does.
///
/// The name is `ShortcutsWalkthrough.shortcutName`, which is also the name
/// the test looks for: if they ever disagree, the tile is the lie and the
/// test is the truth, so they read from one constant.
struct ShortcutCardTile: View {
    let name: String

    private static let size = CGSize(width: 164, height: 164)

    var body: some View {
        VStack(alignment: .leading) {
            Image(systemName: "wave.3.right")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
            Spacer()
            Text(name)
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(AppTheme.Spacing.m)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(AppTheme.Palette.brandPrimary, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
        .elevation(.resting)
    }
}

/// Whether capture has ever actually worked on this phone, and the way to
/// remove onboarding's test purchase if one is still around.
///
/// **"Working" means a real purchase arrived, not that the test passed.**
/// The test proves the shortcut and the intent; only a real Apple Pay tap
/// proves the Wallet automation exists and is bound to the right cards,
/// because iOS exposes no way to inspect a personal automation. So this
/// reads `AppSettings.captureVerifiedAt`, which `CaptureIntent` writes on
/// the first capture that is not the test.
struct CaptureStatusCard: View {
    let session: SessionStore

    @State private var hasTestCapture = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            if let verifiedAt = AppSettings.captureVerifiedAt {
                Label("Working", systemImage: "checkmark.circle.fill")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.statusPositive)
                Text("First purchase captured \(verifiedAt.formatted(.relative(presentation: .named))).")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            } else {
                Label("Waiting for your first purchase", systemImage: "clock")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text("Keepo confirms the automation the moment a real tap-payment lands.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }

            if hasTestCapture {
                Divider()
                // Offered for as long as one exists. The test capture is
                // never auto-deleted — the user made it and the user
                // removes it — so backgrounding the app mid-setup must not
                // be able to strand it with nothing left pointing at it.
                Button {
                    Task { await deleteTestCapture() }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("Delete test purchase")
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.statusNegative)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
        .task(id: session.refresh.token) {
            hasTestCapture = (try? await session.dbQueue.read { try TestCaptureQueries.exists($0) }) ?? false
        }
    }

    private func deleteTestCapture() async {
        isDeleting = true
        try? await session.dbQueue.write { try TestCaptureQueries.delete($0) }
        session.refresh.bump()
        hasTestCapture = false
        isDeleting = false
    }
}
