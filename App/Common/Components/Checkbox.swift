import SwiftUI

/// A square checkbox — the control for "any number of these can be on".
///
/// Square rather than a radio circle on purpose: a circle promises that
/// choosing one clears the others. Extracted when the Export screen's account
/// list needed exactly the box the Custom Range sheet's All Time row already
/// drew, so the two cannot drift into two ideas of a checkbox.
struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.control / 2)
            .strokeBorder(isOn ? AppTheme.Palette.brandPrimary : AppTheme.Palette.fillStrong, lineWidth: 1.5)
            .background(
                isOn ? AppTheme.Palette.brandPrimary : .clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control / 2)
            )
            .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(AppTheme.Typography.captionEmphasis)
                        .foregroundStyle(AppTheme.Palette.textOnAccent)
                }
            }
    }
}

/// A checkbox and its label, bare on the canvas — no card behind it and no
/// explanatory line under it. The "everything" answer that sits over a list
/// of specific ones: All Time over the range calendar, All accounts over
/// Export's account list. What it does is shown by what it sits on (the
/// calendar dims, every account ticks), so it needs no sentence.
///
/// A checkbox rather than a switch: a switch says "a setting that stays on",
/// and this is one answer to a question, which turns itself off the moment a
/// more specific answer is picked.
struct CheckboxRow: View {
    let title: String
    let isOn: Bool
    /// A `KeepoIcon` asset name shown between the box and the label, for a row
    /// whose answer has a glyph elsewhere in the app — the Source filter's
    /// "Automatically captured" wears the same `icon-robot` a captured
    /// transaction wears in the ledger. Optional, and most rows have none: an
    /// icon on every row would make the two that mean something stop meaning
    /// it.
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.m) {
                Checkbox(isOn: isOn)
                // The glyph and the words are **one** label, so they sit at
                // `xs` — the token's own definition is "between an icon and
                // its label". Only the gap back to the box is `m`, which is
                // the gap between two different things.
                //
                // The glyph **trails** the words, so every row in the list
                // starts its text at the same x whether or not it has one.
                // Leading, the icon indented one row's label past its
                // neighbours' and the column of names stopped being a column.
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(AppTheme.Typography.labelEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    if let icon {
                        KeepoIcon(name: icon, size: AppTheme.Size.glyphSmall)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, AppTheme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(AppTheme.Feedback.toggle, trigger: isOn)
    }
}
