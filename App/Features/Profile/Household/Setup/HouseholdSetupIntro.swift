import KeepoCore
import SwiftUI

/// The first screen of the flow: what a household is, and what is about to
/// happen, before anything happens.
///
/// Four illustrated lines rather than a paragraph. The information is not
/// optional — "the person you share with can edit your transactions" is
/// something a user must know before they agree to it, not after — but a
/// wall of text at the start of a flow is read by nobody, which makes it
/// worse than useless: it discharges the obligation to explain without
/// actually explaining. A glyph, four words of heading and one sentence
/// each is the most that gets read.
struct HouseholdSetupIntro: View {
    let role: HouseholdPairingIdentity.Role

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
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.s)
            .padding(.bottom, AppTheme.Spacing.xxl)
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

            Text(role == .owner ? "You're about to create a household" : "You're about to join a household")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                role == .owner
                    ? "A household is two Keepo users seeing the same money. You choose exactly what goes in."
                    : "A household is two Keepo users seeing the same money. You choose exactly what you bring to it."
            )
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppTheme.Spacing.m)
    }

    /// The one thing that is genuinely a caveat rather than a step, kept
    /// apart from the four so it is not read as one of them.
    private var footnote: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            KeepoIcon(name: "icon-info", size: AppTheme.Size.glyphSmall)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text(
                "Nothing is permanent. Either of you can leave, and leaving splits every shared account "
                    + "back into private copies — you each keep everything."
            )
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
                title: "Choose your accounts",
                detail: role == .owner
                    ? "Pick which of your accounts join the household. A shared account is visible "
                        + "and editable by both of you — balances, transactions, everything on it."
                    : "Pick which of your accounts you bring. A shared account is visible and "
                        + "editable by both of you — balances, transactions, everything on it."
            ),
            .init(
                icon: "icon-tag",
                title: "Choose your categories",
                detail: "A shared category is one category on both phones: rename it and it renames "
                    + "for them too. It shares the label, never your spending."
            ),
            .init(
                icon: "icon-tag-filled",
                title: "Tags come along",
                detail: "Every tag on a shared account is shared automatically, and stops being "
                    + "shared the moment that account does."
            ),
            .init(
                icon: "icon-tap",
                title: "Stand next to them",
                detail: role == .owner
                    ? "The person joining needs to be beside you with Keepo open. The two phones "
                        + "find each other directly."
                    : "The person who owns the household needs to be beside you with Keepo open. "
                        + "The two phones find each other directly."
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
