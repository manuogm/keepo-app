import KeepoCore
import SwiftUI

/// A category's icon+color, as a small round badge — the list-row
/// counterpart to `CategoriesView`'s square tiles. `nil` (a transfer, or a
/// row whose category isn't in the cached list yet) renders a neutral
/// placeholder rather than nothing, so row heights never jump.
struct CategoryIconView: View {
    private let icon: String
    private let color: Color
    var diameter: CGFloat = 32

    init(category: PublicSchema.CategoriesSelect?, diameter: CGFloat = 32) {
        self.icon = category?.icon ?? "questionmark"
        self.color = category.map { Color(hex: $0.color) } ?? AppTheme.Palette.textSecondary
        self.diameter = diameter
    }

    /// Renders an explicit icon+color directly, bypassing the `nil`-category
    /// placeholder — for badges that aren't backed by a category (a
    /// transfer), and for one that wants no disc at all: `.clear` leaves the
    /// white glyph alone on whatever is behind it, which is how a selected
    /// `CategoryChoiceTile` draws its icon on its own flooded colour.
    init(icon: String, color: Color, diameter: CGFloat = 32) {
        self.icon = icon
        self.color = color
        self.diameter = diameter
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: diameter * 0.45))
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .frame(width: diameter, height: diameter)
            .background(color)
            .clipShape(Circle())
    }
}
