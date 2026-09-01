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
                    Image(systemName: "pencil")
                        .font(AppTheme.Typography.microEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                        .background(AppTheme.Palette.bgSurface, in: Circle())
                        .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
                }
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Change icon and colour")
    }
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
        Image(systemName: "creditcard.fill")
            .font(AppTheme.Typography.micro)
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

    var body: some View {
        FormErrorText(message: message)
    }
}
