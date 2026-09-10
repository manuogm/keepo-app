import KeepoCore
import SwiftUI

/// The first screen of the flow: what is about to happen, before it happens.
///
/// Six illustrated lines rather than a paragraph. The information is not
/// optional — "the other person can edit your transactions" is something a
/// user must know *before* agreeing to it — but a wall of text at the start
/// of a flow is read by nobody, which makes it worse than useless: it
/// discharges the obligation to explain without explaining. A glyph, a short
/// heading and **one line** each is the most that gets read.
///
/// The last line is the reassurance rather than another instruction, and it
/// sits in the same list as the rest deliberately: it is the answer to the
/// question the other five raise ("what have I just signed up to?"), not a
/// warning to be quarantined in a box.
///
/// The action lives at the end of the scroll, not pinned over it: this page
/// is something to read to the bottom, and a button floating above unread
/// text invites skipping the one screen that exists to be understood.
struct HouseholdSetupIntro<Footer: View>: View {
    let role: HouseholdPairingIdentity.Role
    @ViewBuilder var footer: Footer

    private var tint: Color { PublicSchema.AccountScope.household.tint }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                VStack(spacing: AppTheme.Spacing.l) {
                    ForEach(points, id: \.title) { point in
                        HouseholdIntroPoint(point: point, tint: tint)
                    }
                }
                footer
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.s)
            .padding(.bottom, AppTheme.Spacing.l)
        }
        .background(AppTheme.Palette.bgCanvas)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            KeepoIcon(name: "icon-home-filled", size: AppTheme.Size.icon)
                .foregroundStyle(tint)
                .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                .background(tint.opacity(AppTheme.Opacity.fill), in: Circle())

            Text(role == .owner ? "Create a household" : "Join a household")
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppTheme.Spacing.m)
    }

    /// Points 1 and 2 are the only lines that differ between creating and
    /// joining — one invites, the other accepts. The rest of the deal is
    /// identical from both sides, so it is written once.
    private var points: [HouseholdIntroPoint.Point] {
        [
            .init(
                icon: "icon-shared",
                title: "Share your finances",
                detail: role == .owner
                    ? "Invite your partner, roommate or family member"
                    : "Join your partner, roommate or family member"
            ),
            .init(
                icon: "icon-tap",
                title: "Build your household together",
                detail: role == .owner
                    ? "Ask your guest to join, make decisions and stay close until completion"
                    : "Find a household owner, make decisions and stay close until completion"
            ),
            .init(
                icon: "icon-account",
                title: "Choose accounts to share",
                detail: "Both members can edit and log transactions to them"
            ),
            .init(
                icon: "icon-tag",
                title: "Choose categories to share",
                detail: "Decide to merge common ones or to keep them separated"
            ),
            .init(
                icon: "icon-tag-filled",
                title: "Tags are automatically shared",
                detail: "Only when applied to transactions from shared accounts"
            ),
            .init(
                icon: "icon-info",
                title: "Don't worry, Nothing is permanent",
                detail: "Either member can leave the household anytime and get a private copy "
                    + "of everything. Nothing is lost."
            )
        ]
    }
}

/// One illustrated line of the explanation.
struct HouseholdIntroPoint: View {
    struct Point {
        let icon: String
        let title: String
        let detail: String
    }

    let point: Point
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            KeepoIcon(name: point.icon, size: AppTheme.Size.glyph)
                .foregroundStyle(tint)
                .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                .background(tint.opacity(AppTheme.Opacity.hairline), in: Circle())

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(point.title)
                    .font(AppTheme.Typography.rowTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(point.detail)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
