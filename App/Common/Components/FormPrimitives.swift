import SwiftUI

/// Small shapes the redesigned forms all reach for. They live together
/// because each is a handful of lines that would otherwise be pasted into
/// four screens — the Account, Category, Transaction and Mapped Card forms
/// each need a destructive action, and three of them need the same
/// icon-on-a-coloured-circle button to open the icon catalogue.

/// The centred destructive action every edit form ends with — an outlined
/// red capsule rather than bare red text. Bare text reads as a link at the
/// bottom of a scroll view; an outlined capsule reads as a button you have
/// to aim at, which is the right amount of friction for the only action
/// here that cannot be undone.
struct DestructiveActionButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.statusNegative.opacity(isEnabled ? 1 : 0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.m)
                .overlay {
                    Capsule()
                        .strokeBorder(AppTheme.Palette.statusNegative.opacity(isEnabled ? 0.55 : 0.25), lineWidth: 1.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .disabled(!isEnabled)
    }
}

/// The big tappable icon at the top of the Account and Category forms.
/// Tapping it opens `IconCatalogView`; the chevron-free, label-free
/// treatment is deliberate — the icon *is* the affordance, and a "Change
/// icon" label under it would be exactly the kind of redundant labelling
/// the redesign is removing.
struct IconPickerButton: View {
    let icon: String
    let color: Color
    var diameter: CGFloat = 88
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CategoryIconView(icon: icon, color: color, diameter: diameter)
                .overlay(alignment: .bottomTrailing) {
                    KeepoIcon(name: "icon-edit", size: badgeDiameter / 2)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .frame(width: badgeDiameter, height: badgeDiameter)
                        .background(AppTheme.Palette.bgSurface, in: Circle())
                        .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
                        // Nudged out along the diagonal so the badge rides the
                        // circle's rim instead of sitting on top of the chosen
                        // glyph.
                        .offset(x: badgeDiameter / 4, y: badgeDiameter / 4)
                }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Change icon and colour")
    }

    /// **`max`, not a bare ratio.** The badge has to grow with a hero-sized
    /// well — onboarding's first account draws this at `Size.avatarHero`,
    /// where a fixed 32pt disc reads as a speck — without shrinking or
    /// nudging the badge on every form that already uses the 88pt default.
    /// At that default the ratio lands just under `Size.icon`, so the floor
    /// is what every existing caller keeps drawing.
    private var badgeDiameter: CGFloat { max(AppTheme.Size.icon, diameter * 0.36) }
}

/// The "shared with your household" marker. One component so the Accounts
/// list, the Account form and the transaction detail card can never drift
/// on which glyph means shared.
struct SharedWithHouseholdIcon: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .font(AppTheme.Typography.micro)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .accessibilityLabel("Shared with your household")
    }
}

/// The "has a card mapped" marker for the Accounts list — a glance at
/// whether Apple Pay purchases can auto-capture into this account, without
/// opening the account form to check.
struct MappedCardIcon: View {
    var body: some View {
        KeepoIcon(name: "icon-mappedcard", size: AppTheme.Size.glyphSmall)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .accessibilityLabel("Has a linked card")
    }
}

/// A labelled row whose control sits on the trailing edge, on the form's
/// own card surface. The redesigned forms are not `Form`s any more, so the
/// inset-grouped row look has to be built rather than inherited.
struct FormCard<Content: View>: View {
    var padding = AppTheme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
    }
}

/// The one way a screen tells the user something went wrong.
///
/// Fifteen screens each wrote `Text(message)` with their own font and their
/// own red, and they had already drifted: two of them set no font at all, so
/// the same failure read at body size on Export and at footnote size on the
/// screen beside it. An error is one thing, so it looks like one thing.
///
/// Not for an error drawn on a tinted surface (the Mapped Card sheet) or one
/// that is deliberately quiet (the offline bar's last-sync note) — those are
/// saying something else and are styled where they are said.
struct FormErrorText: View {
    let message: String

    // `Text`, not `FormErrorText`. It returned itself from `body` — introduced
    // in f95e163 and shipped since — which is infinite recursion: every screen
    // that actually rendered an error overflowed the stack and took the app
    // down. It survived because an error message is the one view a screen
    // almost never draws, so nothing exercised it until the avatar upload
    // started failing and tried to say so.
    var body: some View {
        Text(message)
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.statusNegative)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one forward action on a screen — a setup step, sign-in, or the
/// transaction form's "Save and Add Another". Named for the job rather
/// than for onboarding, which is where it started and has not been the
/// only caller for a long time: it now lives beside the other shapes
/// every form reaches for.
///
/// **Disabled is a neutral fill, not a faded accent.** A dimmed amber still
/// reads as a coloured button with white text on it — as a live control
/// someone will tap and be confused by — so the disabled state drops the
/// accent entirely and takes `textSecondary` with it. The difference has to
/// be a difference in *kind*, because "not yet" is what it means.
struct PrimaryActionButton: View {
    let title: String
    var isEnabled = true
    /// Swaps the label for a spinner while a network call is in flight,
    /// keeping the button's own size so nothing reflows around it.
    var isLoading = false
    /// Sign-in's button and the transaction form's span their content; a
    /// setup step's hugs its label in the bottom bar.
    var fillsWidth = false
    let action: () -> Void

    private var isActive: Bool { isEnabled && !isLoading }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, fillsWidth ? 0 : AppTheme.Spacing.xl)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: AppTheme.Size.touchTarget)
                .background(
                    isActive ? AppTheme.Palette.brandPrimary : AppTheme.Palette.fillStrong,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .disabled(!isActive)
        .animation(AppTheme.Motion.colorSafe, value: isActive)
        .sensoryFeedback(AppTheme.Feedback.buttonPress, trigger: title)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView().tint(AppTheme.Palette.textSecondary)
        } else {
            Text(title)
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(isActive ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textSecondary)
        }
    }
}

/// The quieter of the two actions on a screen — onboarding's Back, and
/// the transaction form's "Save and Add Another". An escape hatch or a
/// second path, not the thing the screen is asking for — but
/// **outlined**, so it still reads as a control. Bare text on the
/// canvas, with no fill and no border, read as a label that happened to
/// be tappable.
///
/// The outline rather than a fill is what keeps the hierarchy: same
/// capsule and same height as the primary beside it, so the pair looks
/// deliberate, with the weight carried entirely by the primary's fill.
struct SecondaryActionButton: View {
    let title: String
    /// Matches `PrimaryActionButton`'s own flag, for the one place the
    /// two sit side by side and have to share a row equally.
    var fillsWidth = false
    /// Disabled drops to the neutral `fillStrong` in both the outline and
    /// the label, for the same reason the primary drops its accent: "not
    /// yet" has to look like a different KIND of control, not a faded one.
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.label)
                .foregroundStyle(isEnabled ? AppTheme.Palette.textSecondary : AppTheme.Palette.fillStrong)
                .padding(.horizontal, fillsWidth ? 0 : AppTheme.Spacing.l)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: AppTheme.Size.touchTarget)
                .overlay(
                    Capsule().stroke(
                        isEnabled ? AppTheme.Palette.textSecondary : AppTheme.Palette.fillStrong, lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
