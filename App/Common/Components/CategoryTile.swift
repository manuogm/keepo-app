import KeepoCore
import SwiftUI

/// A category as a tile: its icon in its own colour, its name underneath.
///
/// Extracted from `CategoriesView`, where it was `private`, because
/// onboarding's Categories step draws the same thing for categories that do
/// not exist yet. **It takes the three presentational fields rather than a
/// row**, which is what lets one component serve both: a
/// `PublicSchema.CategoriesSelect` from the local mirror and a
/// `DefaultCategory` from the catalogue have nothing else in common, and a
/// protocol over two types this small would be ceremony.
///
/// `isSelected` draws a ring rather than dimming the unselected ones. A grid
/// where non-selection is signalled by fading reads as "these are
/// unavailable"; a ring reads as "these are chosen", which is what the step
/// is actually asking.
struct CategoryTile: View {
    let name: String
    let icon: String
    let color: String
    /// `nil` on the Categories tab, where a tile is a thing you open rather
    /// than a thing you choose — and where a ring would be meaningless.
    var isSelected: Bool?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: icon)
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.touchTarget, height: AppTheme.Size.touchTarget)
                .background(Color(hex: color))
                .clipShape(Circle())
            Text(name)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // Taller than the content needs, to bring the tile closer to square.
        // At `s` it was a wide, flat strip — which reads as a table row, and
        // this grid is meant to read as a set of things to pick. Stopped at
        // `l` rather than the ~24 an exactly square tile wants: twenty-three
        // categories at that height add a third again to an already long
        // scroll, and the shape is the point rather than the arithmetic.
        .padding(.vertical, AppTheme.Spacing.l)
        .background(tileFill, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .animation(AppTheme.Motion.quick, value: isSelected)
    }
}

extension CategoryTile {
    /// **The tile itself is the selected state**, not a ring around the
    /// icon. A 2pt stroke on a 44pt circle is a detail you have to look for,
    /// and this grid is scanned rather than read — across three columns and
    /// twenty tiles the ring was genuinely hard to count.
    ///
    /// `nil` is the Categories tab, where a tile is a thing you open rather
    /// than a thing you choose: it keeps the bare canvas it has always had,
    /// so that screen does not inherit a surface it never asked for.
    /// Everywhere the tile *is* a control it gets one — white while
    /// unchosen, and a wash of the icon's own colour once it is, so the
    /// selection is coloured by the thing selected.
    fileprivate var tileFill: Color {
        switch isSelected {
        case .none: return .clear
        case .some(true): return Color(hex: color).opacity(AppTheme.Opacity.fill)
        case .some(false): return AppTheme.Palette.bgSurface
        }
    }
}

extension CategoryTile {
    /// The local mirror's own row, for the Categories tab.
    init(category: PublicSchema.CategoriesSelect) {
        self.init(name: category.name, icon: category.icon, color: category.color, isSelected: nil)
    }

    /// The catalogue's, for onboarding — a category that has no row yet.
    init(category: DefaultCategory, isSelected: Bool) {
        self.init(name: category.name, icon: category.icon, color: category.color, isSelected: isSelected)
    }
}
