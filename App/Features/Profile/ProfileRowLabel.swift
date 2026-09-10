import SwiftUI

/// The leading icon and title every row on My Profile is built from.
///
/// The screen used to carry a footer under almost every section, spelling
/// out in a sentence of grey text what the row above it already said. Those
/// are gone and this replaces them: a glyph identifies a row at a glance,
/// which is the job the paragraph was failing to do, and the list is half
/// the height for it.
///
/// Two glyph sources, because the app has two. A name beginning `icon-` is
/// artwork from `Assets.xcassets/Icons` and renders through `KeepoIcon`;
/// anything else is an SF Symbol. The prefix is the asset catalogue's own
/// convention — every custom glyph in the bundle carries it and no SF Symbol
/// does — so the call sites stay a plain string rather than an enum case
/// wrapped around one. Both kinds are drawn into the same
/// `AppTheme.Size.glyph` box, so every title in the list starts on the same
/// vertical line whichever kind sits beside it.
struct ProfileRowLabel: View {
    let icon: String
    let title: String
    /// Always the colour of the label beside it, never a decoration of its
    /// own. The default is the same `textPrimary` the title is set in;
    /// destructive rows pass `statusNegative` and unbuilt ones
    /// `textSecondary` because their *titles* are those colours. Seventeen
    /// brand-orange glyphs down one screen read as seventeen things asking
    /// for attention, which is the opposite of what a settings list is for.
    var tint: Color = AppTheme.Palette.textPrimary

    var body: some View {
        // `s`, not `m`: the glyph is drawn into a `glyph`-sized box but the
        // artwork inside it is `glyphSmall`, so the box already carries a
        // few points of its own slack on the trailing side. At `m` the two
        // added up and every title sat adrift of its icon.
        HStack(spacing: AppTheme.Spacing.s) {
            glyph
            Text(title)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        Group {
            if icon.hasPrefix("icon-") {
                KeepoIcon(name: icon, size: AppTheme.Size.glyphSmall)
            } else {
                Image(systemName: icon)
                    .font(AppTheme.Typography.label)
            }
        }
        .foregroundStyle(tint)
        .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
        .accessibilityHidden(true)
    }
}
