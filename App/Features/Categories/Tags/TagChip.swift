import KeepoCore
import SwiftUI

/// One tag, wherever it appears — the transaction form's chips, the Tags
/// list, the "Category Tags" row in the category form.
///
/// Name only, and one colour for every tag (`Palette.tagTint`). A tag has no
/// icon and no per-tag hue on purpose: categories already own the colourful
/// layer, and giving tags one too would put two competing colour systems on
/// the same screen with nothing telling the user which kind of thing a given
/// chip is.
struct TagChip: View {
    let name: String
    /// Drawn hollow when the chip is a *choice* not yet made — the picker's
    /// unselected rows. Filled means "this tag is on this transaction".
    var isFilled = true

    var body: some View {
        Text(name)
            .font(AppTheme.Typography.label)
            .lineLimit(1)
            .foregroundStyle(isFilled ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textPrimary)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background {
                if isFilled {
                    Capsule().fill(AppTheme.Palette.tagTint)
                } else {
                    Capsule().strokeBorder(AppTheme.Palette.fillStrong, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }
}

/// The dashed "add" affordance beside a row of chips. Was a placeholder with
/// no behaviour until tags existed; it is now the transaction form's way into
/// the picker, and keeps the dashed outline precisely because a dashed
/// border reads as "a slot, not a thing" — it is the one control in the row
/// that is not itself a tag.
struct AddTagButton: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "plus")
                .font(AppTheme.Typography.microEmphasis)
            Text("Add Tag")
                .font(AppTheme.Typography.label)
        }
        .foregroundStyle(AppTheme.Palette.fillStrong)
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
        .background {
            Capsule()
                .strokeBorder(AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .contentShape(Capsule())
    }
}
