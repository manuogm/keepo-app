import KeepoCore
import SwiftUI

// The two shapes `CategoryMergeSheet` puts side by side. Named apart from
// `CategoriesView`'s own `CategoryTile`, which is the grid tile on a
// different screen with a different shape. Split out for the
// project's file-length lint, and because neither knows anything about
// merging — they are a category drawn as a square, and the empty slot where
// one is not chosen yet.

/// One category as a square tile — icon over name, the shape the Categories
/// grid already uses, so a category looks like itself here too.
struct MergeCategoryTile: View {
    let name: String
    let icon: String
    let color: Color
    var isActionable = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            CategoryIconView(icon: icon, color: color, diameter: AppTheme.Size.avatar)
            Text(name)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.m)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .overlay {
            if isActionable {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                    .strokeBorder(
                        PublicSchema.AccountScope.household.tint.opacity(AppTheme.Opacity.fillStrong),
                        lineWidth: 1.5
                    )
            }
        }
    }
}

/// The slot on the right before anything has been chosen.
///
/// Dashed, for the same reason `AddTagButton` is: a dashed outline reads as
/// "a place for a thing", where a solid one reads as a thing that failed to
/// load. It has to be obviously tappable — it is the only instruction on the
/// screen that the user has to act on.
struct MergeEmptyTile: View {
    let label: String
    let isActionable: Bool

    var body: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: isActionable ? "plus" : "minus")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(
                    isActionable
                        ? PublicSchema.AccountScope.household.tint
                        : AppTheme.Palette.fillStrong
                )
                .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                .background(AppTheme.Palette.fillSubtle, in: Circle())
            Text(label)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.m)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card)
                .strokeBorder(
                    isActionable
                        ? PublicSchema.AccountScope.household.tint.opacity(AppTheme.Opacity.fillStrong)
                        : AppTheme.Palette.fillStrong,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
        }
    }
}
