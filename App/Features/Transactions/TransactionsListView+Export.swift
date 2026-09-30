import KeepoCore
import SwiftUI

// The quick way from the ledger to the Export screen, split out of
// TransactionsListView+Filters.swift for the project's file-length lint.

extension TransactionsListView {
    /// The header's controls: export, then the funnel.
    ///
    /// **Both always**, on the user's call — reversing the earlier rule that
    /// showed export only while the filter panel was open. That rule was
    /// written when every filter lived in the panel, so "what you are
    /// exporting" was only legible with the panel down. The account and the
    /// period are pinned to the canvas now and the export starts from those
    /// as much as from the funnel's filters, so there is no longer a state in
    /// which the button is offering something the screen cannot show you.
    var headerActions: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            exportButton
            filterToggle
        }
    }

    /// Export, starting from exactly what is on screen: the account filter
    /// (or, with none, every account the current scope card shows), the
    /// period, and the category, type, author and search filters — so the
    /// Export screen opens with only the format left to choose.
    ///
    /// Beside the funnel, in the banner.
    var exportButton: some View {
        Button {
            exportRequest = ExportRequest(
                accountIds: exportAccountIds, period: ExportPeriod.matching(range, calendar: calendar),
                categoryIds: filter.categoryIds, kinds: filter.kinds,
                createdByIds: filter.createdByIds, sources: filter.sources, search: filter.search
            )
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Export these transactions")
    }

    /// The accounts the ledger is currently showing, named explicitly: the
    /// one the account menu picked, or every live account the scope card
    /// covers. `nil` — every account — only on the Total card with no account
    /// filter, which is the one case where "all" is literally what is shown.
    private var exportAccountIds: Set<UUID>? {
        if let accountId = filter.accountId { return [accountId] }
        let live = filterAccounts.filter { $0.archivedAt == nil }
        switch scope {
        case .total: return nil
        case .me: return Set(live.filter { !$0.isShared }.map(\.id))
        case .household: return Set(live.filter(\.isShared).map(\.id))
        }
    }
}

/// The Export sheet, opened pre-filled from the ledger. A modifier rather than
/// a `.sheet` in the list's body, which is already long enough that one more
/// presentation there costs readability and the file-length lint.
struct ExportSheetModifier: ViewModifier {
    @Binding var request: ExportRequest?
    let session: SessionStore

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            NavigationStack {
                ExportView(session: session, request: request) { self.request = nil }
            }
        }
    }
}
