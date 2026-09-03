import SwiftUI

/// The app's one "remove this" affordance: a red minus in a ringed circle,
/// straddling the top-right corner of the thing it removes.
///
/// It started on the dashboard, where a widget in edit mode wears one. Tags
/// then needed the same gesture — tap a pill, get a way to delete it — and a
/// second red minus drawn slightly differently would have made two controls
/// out of one idea. The ring is `bgSurface` rather than the host's own
/// background so the badge separates from whatever it straddles without the
/// caller having to say what that is.
///
/// The hit area is deliberately larger than the circle: the badge sits on a
/// corner, on things that wobble (a tile in edit mode) or that are barely
/// taller than the badge itself (a tag pill).
struct RemoveBadge: View {
    /// What is being removed, for VoiceOver — "Remove widget", "Delete tag
    /// Coffee". The badge is a bare glyph, so without this it announces
    /// nothing but "minus".
    let label: String
    /// `Size.glyph` suits a dashboard tile. A tag pill is barely taller than
    /// that, so it takes `Size.glyphSmall` — at 24 the badge would cover the
    /// end of the name it belongs to.
    var diameter: CGFloat = AppTheme.Size.glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(AppTheme.Typography.nanoEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                // Red, because this is the one destructive control on the
                // surface it sits on — it has to read as "remove", not as
                // another handle.
                .frame(width: diameter, height: diameter)
                .background(AppTheme.Palette.statusNegative, in: Circle())
                .overlay(Circle().strokeBorder(AppTheme.Palette.bgSurface, lineWidth: 1.5))
                .padding(AppTheme.Spacing.xs)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
