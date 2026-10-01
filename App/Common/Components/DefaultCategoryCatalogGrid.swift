import KeepoCore
import SwiftUI

/// `DefaultCategoryCatalog` as a grid of tiles to tick, expenses then
/// income.
///
/// Shared by onboarding's Categories step and the suggestions sheet a user
/// who skipped that step is offered on the Categories tab. They are the
/// same choice made at two different moments, and should not look like two
/// different choices.
struct DefaultCategoryCatalogGrid: View {
    /// In the order the user ticked them, which is the order they are
    /// written in.
    @Binding var selection: [DefaultCategoryKey]

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.s), count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            group("Expenses", DefaultCategoryCatalog.expenses)
            group("Income", DefaultCategoryCatalog.income)
        }
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: selection)
    }

    private func group(_ title: String, _ categories: [DefaultCategory]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text(title)
                .font(AppTheme.Typography.rowTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            LazyVGrid(columns: Self.columns, spacing: AppTheme.Spacing.s) {
                ForEach(categories) { category in
                    let isSelected = selection.contains(category.key)
                    Button {
                        toggle(category.key)
                    } label: {
                        CategoryTile(category: category, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    /// Appends rather than inserting in catalogue order, which costs
    /// nothing here — categories have no hierarchy, unlike the dashboard's
    /// widgets, so the only thing order affects is the sequence the outbox
    /// writes them in.
    private func toggle(_ key: DefaultCategoryKey) {
        if let index = selection.firstIndex(of: key) {
            selection.remove(at: index)
        } else {
            selection.append(key)
        }
    }
}
