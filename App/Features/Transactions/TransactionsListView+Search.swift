import KeepoCore
import SwiftUI

/// Search: the glyph that opens it, the field it becomes, and the binding
/// between that field and the filter.
///
/// Its own file because it is a control with three parts and a mode of its
/// own — while the field is up it takes the whole drop-down row, and the
/// pills are not drawn at all. Split from TransactionsListView+Filters.swift
/// when that file reached the project's length limit; the pills and this are
/// the two halves it divides into.
///
/// What the field actually searches is not here: `TransactionFilter.search`
/// goes to `LocalTransactionRow`'s one filter clause, which matches the
/// title, merchant, note, category, account and tags, plus the amount when
/// the term reads as a number.
extension TransactionsListView {
    var searchButton: some View {
        Button {
            isSearching = true
        } label: {
            KeepoIcon(name: "icon-search", size: AppTheme.Size.glyph)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search transactions")
    }

    var searchField: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                KeepoIcon(name: "icon-search", size: AppTheme.Size.glyphSmall)
                // Not a list of the fields it searches: there are seven of
                // them now (title, merchant, note, category, account, tag,
                // amount) and naming three of the seven is worse than naming
                // none — it reads as the limit rather than as an example.
                TextField(
                    "",
                    text: searchBinding,
                    prompt: Text("Anything in a transaction")
                        .foregroundStyle(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppTheme.Typography.label)
                .focused($isSearchFieldFocused)
            }
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .tint(AppTheme.Palette.textOnAccent)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong), in: Capsule())

            // A bare cross, no disc behind it — unlike the clear-filters
            // glyph beside the pills, which keeps its filled circle because
            // it sits among other controls and has to read as one of them.
            // This one is alone on its row opposite a field, where the
            // circle was only weight.
            Button {
                filter.search = nil
                isSearching = false
            } label: {
                Image(systemName: "xmark")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        // The field is what the search button was asking for, so it opens
        // focused with the keyboard up rather than costing a second tap on
        // the thing that just appeared. `.task` rather than `.onAppear`:
        // focus set in the same turn the field is inserted does not stick.
        .task { isSearchFieldFocused = true }
    }

    var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }
}
