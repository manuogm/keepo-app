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
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.red.opacity(isEnabled ? 1 : 0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.red.opacity(isEnabled ? 0.55 : 0.25), lineWidth: 1.5)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 2))
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
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .accessibilityLabel("Shared with your household")
    }
}

/// A labelled row whose control sits on the trailing edge, on the form's
/// own card surface. The redesigned forms are not `Form`s any more, so the
/// inset-grouped row look has to be built rather than inherited.
struct FormCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
