import KeepoCore
import SwiftUI

/// What the Household screen is before there is a household.
///
/// Two buttons, and the order matters: **Create** leads because it is the
/// one a user reaching this screen unprompted is doing. Join is what you do
/// when somebody has already asked you to, and a person in that position is
/// looking for the word "join" and will find it wherever it is.
///
/// Deliberately not `ScopeEmptyStateView`. That view explains why a *screen*
/// has gone blank under the current scope and offers one way out; this one is
/// the front door to a feature and has two. Sharing it would mean bending a
/// component built around a single action, which is how a shared component
/// stops being worth sharing.
struct HouseholdBlankState: View {
    var onCreate: () -> Void
    var onJoin: () -> Void

    private var tint: Color { PublicSchema.AccountScope.household.tint }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()

            VStack(spacing: AppTheme.Spacing.m) {
                KeepoIcon(name: "icon-home", size: AppTheme.Size.icon)
                    .foregroundStyle(tint)
                    .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                    .background(tint.opacity(AppTheme.Opacity.fill), in: Circle())

                Text("No household yet")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                Text(
                    "A household is two Keepo users seeing the same money. Share the accounts you "
                        + "choose, keep the rest private, and build it together in one go."
                )
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(spacing: AppTheme.Spacing.m) {
                Button(action: onCreate) {
                    Text("Create Household")
                        .font(AppTheme.Typography.bodyEmphasis)
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.m)
                        .background(tint, in: Capsule())
                }
                .buttonStyle(.pressableCard)

                Button(action: onJoin) {
                    Text("Join Household")
                        .font(AppTheme.Typography.bodyEmphasis)
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.m)
                        .overlay {
                            Capsule().strokeBorder(
                                tint.opacity(AppTheme.Opacity.fillStrong), lineWidth: 1.5
                            )
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressableCard)

                Text("Both of you need to be together, with Keepo open.")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The five things a member should be able to check without asking anybody.
///
/// A popover rather than a screen: each of these is one sentence, they are
/// read once, and pushing a whole view for them would make finding them again
/// a journey. The last one is the only warning, and it is last because it is
/// about undoing something the user has not done yet.
struct HouseholdInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("About your household")
                .font(AppTheme.Typography.rowTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            point(
                "person.2.fill",
                "Both of you own all of it. A shared account is 100% yours and 100% theirs — "
                    + "Keepo never splits a balance between you."
            )
            point(
                "coloncurrencysign.circle.fill",
                "Every figure here is in **your** base currency. Theirs may differ, and the same "
                    + "household will read differently on their phone."
            )
            point(
                "arrow.triangle.2.circlepath",
                "A shared account is visible and editable by both of you. You can share more at "
                    + "any time; stop sharing one and it goes back to being yours alone, with its "
                    + "whole history."
            )
            point(
                "tag.fill",
                "Tags follow their account. Share it and they come with it, unshare it and they go."
            )
            point(
                "exclamationmark.triangle.fill",
                "Leaving splits every shared account into two private copies — one each — and "
                    + "breaks the link for good. It asks for Face ID first."
            )
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: AppTheme.Size.proseWidth)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            Image(systemName: symbol)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(PublicSchema.AccountScope.household.tint)
                .frame(width: AppTheme.Size.glyphSmall)
            Text(.init(text))
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The other member, as much of them as a household member is entitled to see.
///
/// Deliberately a fraction of My Profile. Sharing a household is not sharing
/// an account: their name, their face, when they joined Keepo, and what
/// currency they see their own money in — which is here because it is the one
/// fact that explains why the same household reads differently on their
/// phone. Nothing about their private accounts, and nothing they can change.
struct HouseholdMemberSheet: View {
    let member: HouseholdMemberProfile
    let image: UIImage?
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.l) {
                        identity
                        facts
                        DestructiveActionButton(title: "Remove from Household", action: onRemove)
                            .padding(.top, AppTheme.Spacing.s)
                        Text(
                            "This ends the household for both of you and splits every shared "
                                + "account into two private copies."
                        )
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AppTheme.Spacing.l)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Household Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    private var identity: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            ProfileAvatarView(
                name: member.displayName, email: member.email,
                image: image, size: AppTheme.Size.illustration
            )
            Text(member.displayName ?? "—")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text(member.email ?? "—")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .padding(.top, AppTheme.Spacing.m)
    }

    private var facts: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ProfileMetricCard(title: "Keepo member since") {
                Text(memberSince)
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }
            ProfileMetricCard(title: "Their base currency") {
                if let code = member.baseCurrency {
                    CurrencyBadge(code: code, diameter: AppTheme.Size.glyph)
                } else {
                    Text("—")
                        .font(AppTheme.Typography.cardTitle)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }
        }
    }

    private var memberSince: String {
        guard let raw = member.memberSince,
              let date = PostgresDate.date(fromTimestamp: raw) else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// The other member's avatar bytes, fetched and cached like your own.
///
/// A free function rather than a second `AvatarStore`: that type is an
/// `@Observable` holding exactly one image — the signed-in user's — and every
/// screen in the app reads it. Pointing it at somebody else, even briefly,
/// would swap the face on the scope banner.
///
/// Reachable at all only because `20260913100000` widened `avatars_select` to
/// admit a household member's folder. Before a household exists, the
/// discovery card gets its face over the peer link instead.
enum HouseholdPeerAvatar {
    @MainActor
    static func load(path: String?, session: SessionStore) async -> UIImage? {
        guard let path,
              let url = try? await AvatarRepository.signedURL(client: session.client, path: path),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
