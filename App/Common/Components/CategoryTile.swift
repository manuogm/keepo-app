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
                .overlay {
                    if isSelected == true {
                        Circle()
                            .stroke(AppTheme.Palette.textPrimary, lineWidth: 2)
                            .padding(-AppTheme.Spacing.xxs)
                    }
                }
            Text(name)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.s)
        .animation(AppTheme.Motion.quick, value: isSelected)
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
