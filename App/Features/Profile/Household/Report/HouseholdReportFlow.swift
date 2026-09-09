import KeepoCore
import SwiftUI

/// The owner's review of everything the two of you just pooled, in five
/// screens.
///
/// It exists because the ceremony deliberately does not ask questions. Ten
/// steps of animation with a modal decision in the middle would not be a
/// moment, it would be a wizard with a light show. So every choice that
/// needs a person — which categories are really the same category, which tags
/// are redundant — is gathered here, once, with the whole household in front
/// of the owner and the other phone waiting at 90%.
///
/// **The banner and the container never move.** They are the answer to "what
/// am I looking at", and the whole flow is five different answers to "what is
/// in it" — so only the cards below change, and they change under a heading
/// that stays put.
struct HouseholdReportFlow: View {
    let session: SessionStore
    var myAvatar: UIImage?
    /// Passed in rather than fetched. During the ceremony the household is not
    /// final yet, so `avatars_select` still refuses the other member's folder
    /// — their face exists on this phone only as the bytes that came over the
    /// peer link. The QR path, which has no peer link, passes nil and the
    /// container draws an initial, exactly as it does for a member with no
    /// photo.
    var peerAvatar: UIImage?
    var peerName: String?
    /// Runs when the owner presses Finish. The ceremony passes
    /// `coordinator.finish()`, which fills both houses; the QR fallback,
    /// which has no other phone to tell, passes a plain sync.
    var onFinish: () async -> Void

    @State private var step = 0
    @State private var snapshot = HouseholdSnapshot()
    @State private var isLoading = true
    @State private var isFinishing = false
    @State private var errorMessage: String?

    private static let stepCount = 5

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HouseholdReportBanner(step: step, total: Self.stepCount)

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    body(for: step)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .safeAreaInset(edge: .bottom) { flowBar }
        .task { await load() }
    }

    @ViewBuilder
    private func body(for step: Int) -> some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.l) {
                HouseholdContainer(owner: owner, guest: guest)
                    .padding(.vertical, AppTheme.Spacing.m)

                switch step {
                case 0: HouseholdReportOverview(snapshot: snapshot)
                case 1: HouseholdReportAccounts(snapshot: snapshot, viewer: session.profile?.id)
                case 2:
                    HouseholdReportCategories(session: session, snapshot: snapshot) {
                        Task { await load() }
                    }
                case 3:
                    HouseholdReportTags(session: session, snapshot: snapshot) {
                        Task { await load() }
                    }
                default:
                    HouseholdSummaryCard(session: session, snapshot: snapshot) {
                        Task { await load() }
                    }
                }

                if let errorMessage {
                    FormErrorText(message: errorMessage)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        // A cross-fade keyed on the step, rather than a push: the banner and
        // the container are the same object throughout, and sliding the whole
        // screen would move them too.
        .id(step)
        .transition(.opacity)
    }

    private var flowBar: some View {
        HouseholdFlowBar(
            onBack: step > 0 ? { withAnimation(AppTheme.Motion.standard) { step -= 1 } } : nil,
            nextTitle: step == Self.stepCount - 1 ? "Finish" : "Next",
            isBusy: isFinishing
        ) {
            if step == Self.stepCount - 1 {
                isFinishing = true
                Task {
                    await onFinish()
                    isFinishing = false
                }
            } else {
                withAnimation(AppTheme.Motion.standard) { step += 1 }
            }
        }
    }

    // MARK: - Members

    private var owner: HouseholdMemberView {
        HouseholdMemberView(
            name: session.profile?.displayName ?? session.userEmail ?? "You",
            image: myAvatar,
            isMe: true
        )
    }

    private var guest: HouseholdMemberView {
        HouseholdMemberView(
            name: peerName ?? snapshot.peer?.displayName ?? snapshot.peer?.email ?? "Partner",
            image: peerAvatar,
            isMe: false
        )
    }

    private func load() async {
        snapshot = await HouseholdDataLoader.load(session: session)
        isLoading = false
    }
}

/// The report's own header — the scope banner's shape and colour, holding
/// still.
///
/// Deliberately **not** `ScopeBannerView`. That carousel's entire job is to
/// change which slice of money the app is computing, and there is exactly one
/// slice here. Reusing it would put a swipe gesture on a screen where swiping
/// means nothing, and a deck of cards where there is one card. What is worth
/// sharing is the *look*, and that comes from the same `AccountScope.household
/// .tint` and the same corner radius rather than from the same view.
struct HouseholdReportBanner: View {
    let step: Int
    let total: Int

    @Environment(\.topSafeAreaInset) private var topSafeAreaInset

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            HStack(spacing: AppTheme.Spacing.s) {
                KeepoIcon(name: "icon-home-filled", size: AppTheme.Size.glyphSmall)
                Text("Household Report")
                    .font(AppTheme.Typography.cardTitle)
            }
            .foregroundStyle(AppTheme.Palette.textOnAccent)

            // Where you are in the five, as the same capsule ladder the old
            // invite flow used — the one question every stepped flow has to
            // answer on screen is "how much more of this is there".
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(
                            AppTheme.Palette.textOnAccent
                                .opacity(index <= step ? 1 : AppTheme.Opacity.dim)
                        )
                        .frame(
                            width: index == step ? AppTheme.Spacing.xl : AppTheme.Spacing.s,
                            height: AppTheme.Spacing.xs
                        )
                }
            }
            .animation(AppTheme.Motion.standard, value: step)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.bottom, AppTheme.Spacing.l)
        // The card paints up behind the status bar so the header has no hard
        // colour edge at the top of the screen, exactly as the scope banner
        // does — see `ScopeBannerView`'s own note on why the inset has to
        // come from the environment rather than from local geometry.
        .padding(.top, topSafeAreaInset + AppTheme.Spacing.m)
        .background(PublicSchema.AccountScope.household.tint)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: AppTheme.Radius.surface,
                bottomTrailingRadius: AppTheme.Radius.surface
            )
        )
        .elevation(.resting)
    }
}
