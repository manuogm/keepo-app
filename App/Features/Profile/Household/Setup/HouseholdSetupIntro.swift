import KeepoCore
import SwiftUI

/// The first screen of the flow: what is about to happen, before it happens.
///
/// Four illustrated lines rather than a paragraph. The information is not
/// optional — "the other person can edit your transactions" is something a
/// user must know *before* agreeing to it — but a wall of text at the start
/// of a flow is read by nobody, which makes it worse than useless: it
/// discharges the obligation to explain without explaining. A glyph, two or
/// three words of heading and **one line** each is the most that gets read.
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
                footnote
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

            Text("Two people, one view of the money you choose to share.")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppTheme.Spacing.m)
    }

    /// The one caveat, kept apart from the four steps so it is not read as
    /// another thing to do.
    private var footnote: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            KeepoIcon(name: "icon-info", size: AppTheme.Size.glyphSmall)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text("Either of you can leave. Shared accounts split back into private copies — you each keep everything.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.m)
        .background(AppTheme.Palette.fillSubtle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
    }

    private var points: [HouseholdIntroPoint.Point] {
        [
            .init(
                icon: "icon-account",
                title: "Your accounts",
                detail: "Pick which ones join. Both of you can see and edit a shared account."
            ),
            .init(
                icon: "icon-tag",
                title: "Your categories",
                detail: "One category on both phones. It shares the label, never your spending."
            ),
            .init(
                icon: "icon-tag-filled",
                title: "Tags follow accounts",
                detail: "Every tag on a shared account comes along, and leaves when it does."
            ),
            .init(
                icon: "icon-tap",
                title: "Stay close",
                detail: "The other phone has to be beside you, with Keepo open."
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
